import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "lingbot")

/// Typed, state-machine-aware wrapper around ``Reactor`` for the
/// LingBot model — "action-controlled world generation."
///
/// LingBot's specialty is **persistent action inputs**: `movement`,
/// `lookHorizontal`, `lookVertical` are sticky state, not events. You
/// hold "forward" by setting `.forward` once and leaving it; the model
/// applies it every chunk until you set `.idle`. Treat it like a virtual
/// joystick, not a keyboard buffer.
///
/// ```
///   connect → uploadImage → setImage(ref) → setPrompt("…") → start
///           → setMovement(.forward) → setLookHorizontal(.left)
///           → setMovement(.idle)
///           → pause / resume / reset → disconnect
/// ```
///
/// **Required before `start`:** both a prompt and a seed image. The
/// wrapper doesn't enforce this client-side (the server is
/// authoritative); a missing precondition surfaces as `command_error`
/// on the `start` send.
@MainActor
@Observable
public final class LingBotSession {

    public let reactor: Reactor

    public private(set) var snapshot: LingBot.StateMessage?
    public private(set) var lastCommandError: LingBot.CommandErrorMessage?
    public private(set) var hasStartedRun: Bool = false

    public var status: ReactorStatus { reactor.status }

    private let autoResetOnComplete: Bool
    private var messageHandlers: [UUID: @MainActor (LingBot.Message) -> Void] = [:]
    private var messageSubscription: ReactorSubscription?
    private var statusSubscription: ReactorSubscription?

    /// Create a session bound to a fresh `Reactor(modelName: "lingbot")`.
    ///
    /// - Parameter autoResetOnComplete: when true (default), the
    ///   wrapper sends `reset` after `generation_complete` so subsequent
    ///   commands aren't rejected against the locked session.
    public convenience init(autoResetOnComplete: Bool = true) {
        self.init(reactor: Reactor(modelName: "lingbot"),
                  autoResetOnComplete: autoResetOnComplete)
    }

    public init(reactor: Reactor, autoResetOnComplete: Bool = true) {
        self.reactor = reactor
        self.autoResetOnComplete = autoResetOnComplete
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

    /// Upload the required seed image. Equivalent to
    /// `reactor.uploadFile(...)`; provided here for ergonomic discovery.
    public func uploadImage(data: Data, name: String, mimeType: String = "image/jpeg") async throws -> FileRef {
        try await reactor.uploadFile(data: data, name: name, mimeType: mimeType)
    }

    // ─────────────────────────────────────────────────────────────────
    // Commands (typed)
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_prompt`. Max ~1000 chars server-side.
    public func setPrompt(_ prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_prompt",
                                      payload: LingBot.SetPromptParams(prompt: prompt))
    }

    /// Send `set_image`. Required before `start`.
    public func setImage(_ image: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_image",
                                      payload: LingBot.SetImageParams(image: image))
    }

    /// Send `set_movement`. Sticky — model applies this every chunk
    /// until changed.
    public func setMovement(_ movement: LingBot.Movement) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_movement",
                                      payload: LingBot.SetMovementParams(movement))
    }

    /// Send `set_look_horizontal`. Sticky yaw control.
    public func setLookHorizontal(_ look: LingBot.LookHorizontal) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_look_horizontal",
                                      payload: LingBot.SetLookHorizontalParams(look))
    }

    /// Send `set_look_vertical`. Sticky pitch control.
    public func setLookVertical(_ look: LingBot.LookVertical) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_look_vertical",
                                      payload: LingBot.SetLookVerticalParams(look))
    }

    /// Send `set_rotation_speed_deg`. Range `0.0...30.0`. Applies to
    /// both look axes.
    public func setRotationSpeed(degreesPerChunk: Double) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "set_rotation_speed_deg",
            payload: LingBot.SetRotationSpeedParams(degreesPerChunk: degreesPerChunk)
        )
    }

    /// Begin generating. Server requires prompt + image set first;
    /// missing preconditions surface as `command_error`.
    public func start() async throws {
        try ensureReady()
        if hasStartedRun {
            throw LingBot.LocalError.alreadyStarted
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

    public func reset() async throws {
        try ensureReady()
        try await reactor.sendCommand("reset")
        hasStartedRun = false
    }

    public func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: LingBot.SetSeedParams(seed: seed))
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed handlers
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    public func onMessage(_ handler: @escaping @MainActor (LingBot.Message) -> Void) -> UUID {
        let id = UUID()
        messageHandlers[id] = handler
        return id
    }

    public func off(_ id: UUID) {
        messageHandlers.removeValue(forKey: id)
    }

    @discardableResult
    public func onState(_ handler: @escaping @MainActor (LingBot.StateMessage) -> Void) -> UUID {
        onMessage { msg in if case .state(let s) = msg { handler(s) } }
    }

    @discardableResult
    public func onCommandError(_ handler: @escaping @MainActor (LingBot.CommandErrorMessage) -> Void) -> UUID {
        onMessage { msg in if case .commandError(let e) = msg { handler(e) } }
    }

    @discardableResult
    public func onChunkComplete(_ handler: @escaping @MainActor (LingBot.ChunkCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    public func onGenerationComplete(_ handler: @escaping @MainActor (LingBot.GenerationCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .generationComplete(let g) = msg { handler(g) } }
    }

    // ─────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────

    private func ensureReady() throws {
        guard reactor.status == .ready else {
            throw LingBot.LocalError.notReady(currentStatus: reactor.status)
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
        guard let message = LingBot.Message.decode(from: payload) else { return }
        switch message {
        case .state(let s):
            snapshot = s
            if !s.started, hasStartedRun {
                hasStartedRun = false
            }
        case .commandError(let e):
            log.error("command_error [\(e.command, privacy: .public)]: \(e.reason, privacy: .public)")
            lastCommandError = e
        case .generationComplete:
            hasStartedRun = false
            if autoResetOnComplete {
                Task { [weak self] in
                    try? await self?.reset()
                }
            }
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
