import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "sana-streaming")

/// Typed, state-machine-aware wrapper around ``Reactor`` for the
/// SANA-Streaming model — real-time **video-to-video editing**.
///
/// SANA-Streaming's specialty is mid-stream **anchor re-grounding**. The
/// model re-references the source video every `anchorInterval` chunks
/// (default 20) to keep the edited output faithful. Set `0` via
/// ``setAnchorInterval(chunks:)`` to let the model drift creatively;
/// lower values keep edits tight at the cost of coherence.
///
/// ```
///   connect → setMode(.file) → uploadVideo → setVideo(ref) → setPrompt("…") → start
///           → setPrompt("…")                ← prompt mid-edit at next chunk
///           → setAnchorInterval(chunks: 8)  ← re-ground more often
///           → pause / resume / reset → disconnect
/// ```
///
/// Live camera input (``SanaStreaming/Mode/live``) requires sendonly
/// `publishTrack` support which is stubbed in v0.2 — calls to
/// ``setMode(_:)`` with `.live` throw
/// ``SanaStreaming/LocalError/liveModeNotYetSupported`` from this
/// wrapper, even though the server accepts the raw command. The check
/// keeps consumers honest about what the SDK can actually deliver
/// end-to-end.
@MainActor
@Observable
public final class SanaStreamingSession {

    public let reactor: Reactor

    public private(set) var snapshot: SanaStreaming.StateMessage?
    public private(set) var lastCommandError: SanaStreaming.CommandErrorMessage?
    public private(set) var hasStartedRun: Bool = false

    public var status: ReactorStatus { reactor.status }

    private let autoResetOnComplete: Bool
    private var messageHandlers: [UUID: @MainActor (SanaStreaming.Message) -> Void] = [:]
    private var messageSubscription: ReactorSubscription?
    private var statusSubscription: ReactorSubscription?

    public convenience init(autoResetOnComplete: Bool = true) {
        self.init(reactor: Reactor(modelName: "sana-streaming"),
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

    /// Upload a source clip (file mode). Convenience around
    /// ``Reactor/uploadFile(data:name:mimeType:)`` with a sensible MIME
    /// default for `.mp4`. Returns the `FileRef` to hand to
    /// ``setVideo(_:)``.
    public func uploadVideo(data: Data, name: String, mimeType: String = "video/mp4") async throws -> FileRef {
        try await reactor.uploadFile(data: data, name: name, mimeType: mimeType)
    }

    // ─────────────────────────────────────────────────────────────────
    // Commands (typed)
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_mode`. Live mode requires `publishTrack`, currently a
    /// v0.2 stub — this wrapper throws
    /// ``SanaStreaming/LocalError/liveModeNotYetSupported`` to keep the
    /// SDK honest about what it can deliver end-to-end.
    public func setMode(_ mode: SanaStreaming.Mode) async throws {
        try ensureReady()
        if mode == .live {
            throw SanaStreaming.LocalError.liveModeNotYetSupported
        }
        try await reactor.sendCommand("set_mode",
                                      payload: SanaStreaming.SetModeParams(mode))
    }

    /// Send `set_video`. File mode only — pair with
    /// ``uploadVideo(data:name:mimeType:)``.
    public func setVideo(_ video: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_video",
                                      payload: SanaStreaming.SetVideoParams(video: video))
    }

    /// Send `set_prompt`. Editing instruction; mid-run changes apply at
    /// the next chunk boundary.
    public func setPrompt(_ prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_prompt",
                                      payload: SanaStreaming.SetPromptParams(prompt: prompt))
    }

    public func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: SanaStreaming.SetSeedParams(seed: seed))
    }

    /// Send `set_anchor_interval`. Re-ground every N chunks. `0`
    /// disables re-anchoring; default `20`.
    public func setAnchorInterval(chunks: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_anchor_interval",
                                      payload: SanaStreaming.SetAnchorIntervalParams(chunks: chunks))
    }

    public func start() async throws {
        try ensureReady()
        if hasStartedRun {
            throw SanaStreaming.LocalError.alreadyStarted
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

    // ─────────────────────────────────────────────────────────────────
    // Typed handlers
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    public func onMessage(_ handler: @escaping @MainActor (SanaStreaming.Message) -> Void) -> UUID {
        let id = UUID()
        messageHandlers[id] = handler
        return id
    }

    public func off(_ id: UUID) {
        messageHandlers.removeValue(forKey: id)
    }

    @discardableResult
    public func onState(_ handler: @escaping @MainActor (SanaStreaming.StateMessage) -> Void) -> UUID {
        onMessage { msg in if case .state(let s) = msg { handler(s) } }
    }

    @discardableResult
    public func onCommandError(_ handler: @escaping @MainActor (SanaStreaming.CommandErrorMessage) -> Void) -> UUID {
        onMessage { msg in if case .commandError(let e) = msg { handler(e) } }
    }

    @discardableResult
    public func onChunkComplete(_ handler: @escaping @MainActor (SanaStreaming.ChunkCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    public func onAnchored(_ handler: @escaping @MainActor (SanaStreaming.AnchoredMessage) -> Void) -> UUID {
        onMessage { msg in if case .anchored(let a) = msg { handler(a) } }
    }

    @discardableResult
    public func onGenerationComplete(_ handler: @escaping @MainActor (SanaStreaming.GenerationCompleteMessage) -> Void) -> UUID {
        onMessage { msg in if case .generationComplete(let g) = msg { handler(g) } }
    }

    // ─────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────

    private func ensureReady() throws {
        guard reactor.status == .ready else {
            throw SanaStreaming.LocalError.notReady(currentStatus: reactor.status)
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
        guard let message = SanaStreaming.Message.decode(from: payload) else { return }
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
