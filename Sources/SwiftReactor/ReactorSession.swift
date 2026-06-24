import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "session")

/// Typed, state-machine-aware wrapper around ``Reactor`` for any
/// supported Reactor model. One class, model is a type parameter.
///
/// ```swift
/// let session = try await ReactorSession<LongLiveV2>.connect(jwt: …)
/// try await session.setShot(prompt: "wide third-person golf shot")
/// try await session.start()
/// ```
///
/// **Compile-time model safety.** The per-command surface lives in
/// constrained extensions (`extension ReactorSession where Model ==
/// LongLiveV2 { setShot, sceneCut, … }`). Calling a wrong-model
/// command on the wrong session is a *compile* error, not a runtime
/// throw — `session.setMovement(.forward)` on a `ReactorSession<LongLiveV2>`
/// won't even autocomplete.
///
/// What the wrapper enforces beyond ``Reactor``:
///
/// 1. **`start()` is idempotent at the SDK boundary.** A second
///    call while ``hasStartedRun`` throws the model's
///    `.alreadyStarted` local error instead of shipping a
///    wire-rejected `start`.
/// 2. **Snapshot mirrors the server's authoritative `state`** —
///    cleared on disconnect so a reconnect can't see stale state.
/// 3. **`command_error` is surfaced** both via the callback and the
///    mirrored ``lastCommandError`` property.
/// 4. **Auto-reset on generation_complete** for models that emit
///    that event (configurable via `autoResetOnComplete`).
@MainActor
@Observable
public final class ReactorSession<Model: ReactorModelKind> {

    /// Underlying generic ``Reactor``. Use directly for things the
    /// typed layer doesn't model (custom commands, `ReactorView`
    /// SwiftUI binding).
    public let reactor: Reactor

    /// Latest `state` message from the server, or `nil` before the
    /// first one arrives / after disconnect.
    public private(set) var snapshot: Model.StateMessage?

    /// Latest `command_error`, or `nil` if no command has been
    /// rejected since the session was last cleared.
    public private(set) var lastCommandError: Model.CommandErrorMessage?

    /// True between a successful `start()` and the next `reset()`
    /// (or the server pushing `started=false` in a state message).
    public private(set) var hasStartedRun: Bool = false

    public var status: ReactorStatus { reactor.status }

    let autoResetOnComplete: Bool
    private var messageHandlers: [UUID: @MainActor (Model.Message) -> Void] = [:]
    private var messageSubscription: ReactorSubscription?
    private var statusSubscription: ReactorSubscription?

    // ─────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────

    /// Bind to an existing ``Reactor``. Use this for shared-`Reactor`
    /// patterns (one transport, multiple typed wrappers) or
    /// `MockTransport`-backed tests. For app code prefer
    /// ``connect(jwt:autoResumeTracks:autoResetOnComplete:)``.
    ///
    /// - Parameter autoResetOnComplete: when true (default), the
    ///   wrapper transparently sends `reset` to the server after a
    ///   `generation_complete` so subsequent commands aren't rejected.
    ///   No-op for models without a `generation_complete` event
    ///   (Helios streams indefinitely).
    public init(reactor: Reactor, autoResetOnComplete: Bool = true) {
        self.reactor = reactor
        self.autoResetOnComplete = autoResetOnComplete
        wireSubscriptions()
    }

    /// Create + bind a fresh `Reactor(model: Model.asModel)`. Handy
    /// for SwiftUI `@State` declarations that want a session handle
    /// before connect:
    ///
    /// ```swift
    /// @State private var session = ReactorSession<LongLiveV2>()
    /// ```
    public convenience init(autoResetOnComplete: Bool = true) {
        self.init(reactor: Reactor(model: Model.asModel),
                  autoResetOnComplete: autoResetOnComplete)
    }

    // ─────────────────────────────────────────────────────────────────
    // Connection lifecycle
    // ─────────────────────────────────────────────────────────────────

    /// Instantiate, connect, and return a ready session in one
    /// `try await`. The canonical entry point for app code.
    public static func connect(
        jwt: JWTSource,
        autoResumeTracks: Bool = true,
        autoResetOnComplete: Bool = true
    ) async throws -> ReactorSession<Model> {
        let reactor = Reactor(model: Model.asModel)
        let session = ReactorSession<Model>(
            reactor: reactor,
            autoResetOnComplete: autoResetOnComplete
        )
        try await reactor.connect(jwt: jwt, autoResumeTracks: autoResumeTracks)
        return session
    }

    /// Convenience that uses the JWT installed via
    /// ``SwiftReactor/configure(jwt:)``. Throws
    /// ``SwiftReactor/Error/notConfigured`` if no global default is
    /// set.
    public static func connect(
        autoResumeTracks: Bool = true,
        autoResetOnComplete: Bool = true
    ) async throws -> ReactorSession<Model> {
        try await connect(
            jwt: Reactor.requireConfiguredJWT(),
            autoResumeTracks: autoResumeTracks,
            autoResetOnComplete: autoResetOnComplete
        )
    }

    public func disconnect() async {
        await reactor.disconnect()
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed handlers (shared across all models)
    // ─────────────────────────────────────────────────────────────────

    /// Subscribe to every typed message for this session's model.
    /// Returns an opaque token; pass it back to ``off(_:)`` to remove.
    @discardableResult
    public func onMessage(
        _ handler: @escaping @MainActor (Model.Message) -> Void
    ) -> UUID {
        let id = UUID()
        messageHandlers[id] = handler
        return id
    }

    public func off(_ id: UUID) {
        messageHandlers.removeValue(forKey: id)
    }

    /// Subscribe to the model's authoritative `state` snapshot.
    @discardableResult
    public func onState(
        _ handler: @escaping @MainActor (Model.StateMessage) -> Void
    ) -> UUID {
        onMessage { msg in
            if let s = Model.extractState(msg) { handler(s) }
        }
    }

    /// Subscribe to server-side `command_error` rejections.
    @discardableResult
    public func onCommandError(
        _ handler: @escaping @MainActor (Model.CommandErrorMessage) -> Void
    ) -> UUID {
        onMessage { msg in
            if let e = Model.extractCommandError(msg) { handler(e) }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Shared command machinery — used by per-model command extensions
    // ─────────────────────────────────────────────────────────────────

    /// Throws ``Model.LocalError`` if the underlying ``Reactor``
    /// isn't `.ready`. Per-model command extensions call this before
    /// every send.
    func ensureReady() throws {
        guard reactor.status == .ready else {
            throw Model.notReadyError(currentStatus: reactor.status)
        }
    }

    /// Atomic guard for `start`: throws `.alreadyStarted` if a run
    /// is in progress, otherwise sends the wire command and flips
    /// ``hasStartedRun``. Per-model extensions just call this.
    func startRun() async throws {
        try ensureReady()
        if hasStartedRun {
            throw Model.alreadyStartedError
        }
        try await reactor.sendCommand("start")
        hasStartedRun = true
    }

    /// `reset` is always safe to send; clears ``hasStartedRun``
    /// locally even if the wire send fails.
    func resetRun() async throws {
        try ensureReady()
        try await reactor.sendCommand("reset")
        hasStartedRun = false
    }

    // ─────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────

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
        guard let message = Model.decode(payload: payload) else { return }

        if let snap = Model.extractState(message) {
            snapshot = snap
            if Model.snapshotIndicatesStopped(snap), hasStartedRun {
                hasStartedRun = false
            }
        }
        if let cmdErr = Model.extractCommandError(message) {
            log.error("command_error received (model=\(String(describing: Model.self), privacy: .public))")
            lastCommandError = cmdErr
        }
        if Model.isGenerationComplete(message) {
            hasStartedRun = false
            if autoResetOnComplete {
                Task { [weak self] in
                    try? await self?.resetRun()
                }
            }
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
