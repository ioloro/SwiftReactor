import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "helios")

/// Typed, state-machine-aware wrapper around ``Reactor`` for the Helios
/// model. Mirrors the JS / Python SDK's `HeliosModel`.
///
/// Helios is **chunked autoregressive** real-time video — 33 frames per
/// chunk at 24fps. The pattern:
///
/// ```
///   connect → setConditioning(prompt: …, image: ref) → start
///           → schedulePrompt(at: 6, prompt: …)        ← cinematic timing
///           → setImageStrength(…) → setImage(…)       ← re-anchor
///           → pause / resume / reset                  ← transport ctl
///           → disconnect
/// ```
///
/// What the wrapper enforces beyond ``Reactor``:
///
///   1. `start()` is idempotent at the SDK boundary (second call throws
///      ``Helios/LocalError/alreadyStarted`` instead of a wire-rejected
///      `start`).
///   2. Snapshot (``snapshot``) tracks the server's authoritative
///      `state` message; cleared on disconnect so a reconnect can't see
///      stale `currentChunk`.
///   3. `command_error` is surfaced both via the callback and the
///      mirrored ``lastCommandError`` property — no silent rejections.
@MainActor
@Observable
public final class HeliosSession {

    /// Underlying generic ``Reactor``. Use directly for things the
    /// typed layer doesn't model (raw commands, `<ReactorView>` UI).
    public let reactor: Reactor

    /// Latest `state` message from the server, or `nil` before the
    /// first one arrives / after disconnect.
    public private(set) var snapshot: Helios.StateMessage?

    /// Latest `command_error`, or `nil` if no command has been rejected
    /// since the session was last cleared.
    public private(set) var lastCommandError: Helios.CommandErrorMessage?

    /// True between a successful `start()` and the next `reset()`.
    public private(set) var hasStartedRun: Bool = false

    public var status: ReactorStatus { reactor.status }

    private var messageHandlers: [UUID: @MainActor (Helios.Message) -> Void] = [:]
    private var messageSubscription: ReactorSubscription?
    private var statusSubscription: ReactorSubscription?

    /// Create a session bound to a fresh `Reactor(modelName: "helios")`.
    public convenience init() {
        self.init(reactor: Reactor(modelName: "helios"))
    }

    /// Create a session bound to an existing ``Reactor``. Useful for
    /// tests (inject a `Reactor` wired to a `MockTransport`) or sharing
    /// a `Reactor` across multiple typed wrappers.
    public init(reactor: Reactor) {
        self.reactor = reactor
        wireSubscriptions()
    }

    // ─────────────────────────────────────────────────────────────────
    // Connection lifecycle
    // ─────────────────────────────────────────────────────────────────

    public func connect(jwt: JWTSource, autoResumeTracks: Bool = true) async throws {
        try await reactor.connect(jwt: jwt, autoResumeTracks: autoResumeTracks)
    }

    public func disconnect() async {
        await reactor.disconnect()
    }

    /// Upload a reference image. Convenience for the common Helios
    /// pattern of `uploadFile` → `setImage`; for atomic prompt+image
    /// updates use ``setConditioning(prompt:image:)``.
    public func uploadImage(data: Data, name: String, mimeType: String = "image/jpeg") async throws -> FileRef {
        try await reactor.uploadFile(data: data, name: name, mimeType: mimeType)
    }

    // ─────────────────────────────────────────────────────────────────
    // Commands (typed)
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_prompt`. Before `start`, seeds chunk 0; after `start`,
    /// applies at the next chunk boundary.
    public func setPrompt(_ prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_prompt",
                                      payload: Helios.SetPromptParams(prompt: prompt))
    }

    /// Send `schedule_prompt`. Apply `prompt` exactly at cumulative
    /// chunk `chunk`. Past chunks are rejected during active generation.
    public func schedulePrompt(_ prompt: String, atChunk chunk: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "schedule_prompt",
            payload: Helios.SchedulePromptParams(prompt: prompt, chunk: chunk)
        )
    }

    /// Send `set_image`. Sets or swaps the reference image used for
    /// conditioning.
    public func setImage(_ image: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_image",
                                      payload: Helios.SetImageParams(image: image))
    }

    /// Send `set_conditioning`. Atomically updates prompt + reference
    /// image — prefer this over sequential `setPrompt` + `setImage`
    /// when both change together.
    public func setConditioning(prompt: String, image: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "set_conditioning",
            payload: Helios.SetConditioningParams(prompt: prompt, image: image)
        )
    }

    /// Send `set_image_strength`. Range `0.0...1.0`; doesn't apply until
    /// the next `set_image` / `set_conditioning` (or after `reset`).
    public func setImageStrength(_ strength: Double) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_image_strength",
                                      payload: Helios.SetImageStrengthParams(strength: strength))
    }

    /// Send `set_sr_scale`. Off / 2x / 4x super-resolution upscaling.
    public func setSRScale(_ scale: Helios.SRScale) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_sr_scale",
                                      payload: Helios.SetSRScaleParams(scale: scale))
    }

    /// Begin generating. Idempotent at the SDK boundary — a second
    /// `start()` while `hasStartedRun` throws
    /// ``Helios/LocalError/alreadyStarted``.
    public func start() async throws {
        try ensureReady()
        if hasStartedRun {
            throw Helios.LocalError.alreadyStarted
        }
        try await reactor.sendCommand("start")
        hasStartedRun = true
    }

    public func pause() async throws {
        try ensureReady()
        try await reactor.sendCommand("pause")
    }

    public func resume() async throws {
        try ensureReady()
        try await reactor.sendCommand("resume")
    }

    /// Stop and clear scheduled prompts, prompt history, and reference
    /// image. Configured seed is preserved (per server semantics).
    public func reset() async throws {
        try ensureReady()
        try await reactor.sendCommand("reset")
        hasStartedRun = false
    }

    public func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: Helios.SetSeedParams(seed: seed))
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed handlers
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    public func onMessage(_ handler: @escaping @MainActor (Helios.Message) -> Void) -> UUID {
        let id = UUID()
        messageHandlers[id] = handler
        return id
    }

    public func off(_ id: UUID) {
        messageHandlers.removeValue(forKey: id)
    }

    @discardableResult
    public func onState(_ handler: @escaping @MainActor (Helios.StateMessage) -> Void) -> UUID {
        onMessage { msg in if case .state(let s) = msg { handler(s) } }
    }

    @discardableResult
    public func onCommandError(_ handler: @escaping @MainActor (Helios.CommandErrorMessage) -> Void) -> UUID {
        onMessage { msg in if case .commandError(let e) = msg { handler(e) } }
    }

    @discardableResult
    public func onChunkComplete(_ handler: @escaping @MainActor (Helios.ChunkCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    public func onConditionsReady(_ handler: @escaping @MainActor (Helios.ConditionsReadyMessage) -> Void) -> UUID {
        onMessage { msg in if case .conditionsReady(let c) = msg { handler(c) } }
    }

    // ─────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────

    private func ensureReady() throws {
        guard reactor.status == .ready else {
            throw Helios.LocalError.notReady(currentStatus: reactor.status)
        }
    }

    private func wireSubscriptions() {
        messageSubscription = reactor.onMessage { [weak self] payload in
            self?.handleIncoming(payload)
        }
        statusSubscription = reactor.on(.statusChanged) { [weak self] event in
            if case .statusChanged(let s) = event, s == .disconnected {
                self?.clearLocalState()
            }
        }
    }

    private func handleIncoming(_ payload: AnyCodable) {
        guard let message = Helios.Message.decode(from: payload) else { return }
        switch message {
        case .state(let s):
            snapshot = s
            if !s.started, hasStartedRun {
                hasStartedRun = false
            }
        case .commandError(let e):
            log.error("command_error [\(e.command, privacy: .public)]: \(e.reason, privacy: .public)")
            lastCommandError = e
        default:
            break
        }
        for handler in messageHandlers.values {
            handler(message)
        }
    }

    private func clearLocalState() {
        snapshot = nil
        lastCommandError = nil
        hasStartedRun = false
    }
}
