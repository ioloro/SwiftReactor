import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "longlive-v2")

/// Typed, state-machine-aware wrapper around `Reactor` for the
/// LongLive-v2 model. Mirrors the JS SDK's `@reactor-models/longlive-v2`
/// surface (`useLongliveV2()` and friends).
///
/// Lifecycle (terms in **bold** are also the wire commands):
/// ```
///   connect → [setShot opener → start] → [setShot | sceneCut | scheduleShot | scheduleSceneCut]*
///                                      → pause/resume freely
///                                      → reset to start a new run
///                                      → disconnect
/// ```
///
/// What the wrapper enforces that raw `Reactor` does not:
///
///   1. `start()` is idempotent at the SDK boundary. The second call
///      throws `LongLiveV2.LocalError.alreadyStarted` instead of
///      shipping a wire-rejected `start`. (This is exactly the trap
///      Sunnyside hit before the typed layer existed.)
///   2. After `generation_complete`, the wrapper auto-calls `reset` so
///      the next `setShot`/`start` is a clean opener. Disable via
///      `autoResetOnComplete: false` in the initializer if you need
///      precise control of the locked-run window.
///   3. The `snapshot` property mirrors the server's `state` message,
///      and is cleared on disconnect so a reconnect can't see stale
///      `sessionChunk` from a previous run.
///   4. Schedule param structs use the literal wire keys
///      (`at_session_chunk`); call sites can't accidentally send a
///      misnamed key that the server silently treats as `-1`.
///   5. `command_error` messages are surfaced as a typed callback and
///      mirrored to `lastCommandError`, so a rejected command can never
///      go silent.
///
/// SwiftUI bindings: this class is `@Observable`, so reading
/// `session.snapshot?.currentChunk` from a view auto-tracks updates.
@MainActor
@Observable
public final class LongLiveV2Session {

    /// The underlying generic `Reactor`. Use directly for things the
    /// typed layer doesn't model (custom commands, base-SDK clip
    /// recording, the `<ReactorView>` UI binding).
    public let reactor: Reactor

    /// Latest `state` message from the server, or `nil` before the
    /// first one arrives / after disconnect.
    public private(set) var snapshot: LongLiveV2.StateMessage?

    /// Latest `command_error` message, or `nil` if no command has been
    /// rejected since the session was last cleared. Mirrors what the
    /// typed `onCommandError` handler also delivers.
    public private(set) var lastCommandError: LongLiveV2.CommandErrorMessage?

    /// True between a successful `start()` and the next `reset()` (or
    /// natural `generation_complete`). The state machine uses this to
    /// reject double-`start` locally.
    public private(set) var hasStartedRun: Bool = false

    public var status: ReactorStatus { reactor.status }

    private let autoResetOnComplete: Bool
    private var messageHandlers: [UUID: @MainActor (LongLiveV2.Message) -> Void] = [:]
    private var messageSubscription: ReactorSubscription?
    private var statusSubscription: ReactorSubscription?

    /// Create a session bound to a fresh `Reactor(modelName:
    /// "longlive-v2")`.
    ///
    /// - Parameter autoResetOnComplete: when true (default), the
    ///   wrapper transparently sends `reset` to the server after a
    ///   `generation_complete` so subsequent commands aren't rejected.
    ///   Disable if you want to handle the locked-run window manually
    ///   (e.g., to surface a "session ended" UI before unlocking).
    public convenience init(autoResetOnComplete: Bool = true) {
        self.init(reactor: Reactor(modelName: "longlive-v2"),
                  autoResetOnComplete: autoResetOnComplete)
    }

    /// Create a session bound to an existing `Reactor`. Useful for
    /// tests (inject a Reactor wired to a `MockTransport`) or when you
    /// want to share a `Reactor` across multiple typed wrappers.
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

    // ─────────────────────────────────────────────────────────────────
    // Commands (typed)
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_shot`. Before `start`, seeds the opener; after `start`,
    /// triggers a soft shot change at the next chunk boundary.
    public func setShot(prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_shot",
                                      payload: LongLiveV2.SetShotParams(prompt: prompt))
    }

    /// Send `scene_cut`. Hard break to a new scene — memory wiped,
    /// per-scene 48-chunk budget reset.
    public func sceneCut(prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("scene_cut",
                                      payload: LongLiveV2.SceneCutParams(prompt: prompt))
    }

    /// Schedule a soft shot change at an absolute `session_chunk`.
    public func scheduleShot(prompt: String, atSessionChunk: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "schedule_shot",
            payload: LongLiveV2.ScheduleShotParams(prompt: prompt, atSessionChunk: atSessionChunk)
        )
    }

    /// Schedule a hard scene cut at an absolute `session_chunk`.
    public func scheduleSceneCut(prompt: String, atSessionChunk: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "schedule_scene_cut",
            payload: LongLiveV2.ScheduleSceneCutParams(prompt: prompt, atSessionChunk: atSessionChunk)
        )
    }

    /// Begin generating from the opening shot. Idempotent at the SDK
    /// boundary: a second call while `hasStartedRun` throws
    /// `LongLiveV2.LocalError.alreadyStarted` rather than sending a
    /// wire-rejected `start`.
    public func start() async throws {
        try ensureReady()
        if hasStartedRun {
            throw LongLiveV2.LocalError.alreadyStarted
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

    /// Abort the current run and clear all scheduled state. Always
    /// succeeds on the server — there is no `command_error` path for
    /// `reset`. After this the session is back to the just-connected
    /// state; `setShot` then `start` are required before generation.
    public func reset() async throws {
        try ensureReady()
        try await reactor.sendCommand("reset")
        hasStartedRun = false
    }

    public func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: LongLiveV2.SetSeedParams(seed: seed))
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed handlers (mirror useLongliveV2State / useLongliveV2CommandError)
    // ─────────────────────────────────────────────────────────────────

    /// Subscribe to every typed LongLive-v2 message. Returns an opaque
    /// token; pass it back to `off(_:)` to remove the handler.
    @discardableResult
    public func onMessage(_ handler: @escaping @MainActor (LongLiveV2.Message) -> Void) -> UUID {
        let id = UUID()
        messageHandlers[id] = handler
        return id
    }

    public func off(_ id: UUID) {
        messageHandlers.removeValue(forKey: id)
    }

    @discardableResult
    public func onState(_ handler: @escaping @MainActor (LongLiveV2.StateMessage) -> Void) -> UUID {
        onMessage { msg in if case .state(let s) = msg { handler(s) } }
    }

    @discardableResult
    public func onCommandError(_ handler: @escaping @MainActor (LongLiveV2.CommandErrorMessage) -> Void) -> UUID {
        onMessage { msg in if case .commandError(let e) = msg { handler(e) } }
    }

    @discardableResult
    public func onChunkComplete(_ handler: @escaping @MainActor (LongLiveV2.ChunkCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    public func onGenerationComplete(_ handler: @escaping @MainActor (LongLiveV2.GenerationCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .generationComplete(let g) = msg { handler(g) } }
    }

    // ─────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────

    private func ensureReady() throws {
        guard reactor.status == .ready else {
            throw LongLiveV2.LocalError.notReady(currentStatus: reactor.status)
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
        guard let message = LongLiveV2.Message.decode(from: payload) else { return }
        switch message {
        case .state(let s):
            snapshot = s
            // Server flips `started=false` on natural completion (or
            // explicit reset). Mirror that locally so the next start
            // isn't blocked by a stale flag.
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
