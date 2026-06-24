import Foundation

/// SANA-Streaming command surface on ``ReactorSession``. Only
/// available when `Model == SanaStreaming`; calling these on a
/// session of any other model is a compile-time error.
public extension ReactorSession where Model == SanaStreaming {

    // ─────────────────────────────────────────────────────────────────
    // Convenience: video upload
    // ─────────────────────────────────────────────────────────────────

    /// Upload a source clip (file mode). Convenience around
    /// ``Reactor/uploadFile(data:name:mimeType:)`` with a sensible
    /// MIME default for `.mp4`. Returns the `FileRef` to hand to
    /// ``setVideo(_:)``.
    func uploadVideo(
        data: Data,
        name: String,
        mimeType: String = "video/mp4"
    ) async throws -> FileRef {
        try await reactor.uploadFile(data: data, name: name, mimeType: mimeType)
    }

    // ─────────────────────────────────────────────────────────────────
    // Commands
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_mode`. Live mode requires `publishTrack`, currently
    /// a v0.3 stub — this wrapper throws
    /// ``SanaStreaming/LocalError/liveModeNotYetSupported`` to keep
    /// the SDK honest about what it can deliver end-to-end.
    func setMode(_ mode: SanaStreaming.Mode) async throws {
        try ensureReady()
        if mode == .live {
            throw SanaStreaming.LocalError.liveModeNotYetSupported
        }
        try await reactor.sendCommand("set_mode",
                                      payload: SanaStreaming.SetModeParams(mode))
    }

    /// Send `set_video`. File mode only — pair with
    /// ``uploadVideo(data:name:mimeType:)``.
    func setVideo(_ video: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_video",
                                      payload: SanaStreaming.SetVideoParams(video: video))
    }

    /// Send `set_prompt`. Editing instruction; mid-run changes apply
    /// at the next chunk boundary.
    func setPrompt(_ prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_prompt",
                                      payload: SanaStreaming.SetPromptParams(prompt: prompt))
    }

    func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: SanaStreaming.SetSeedParams(seed: seed))
    }

    /// Send `set_anchor_interval`. Re-ground every N chunks. `0`
    /// disables re-anchoring; default `20`.
    func setAnchorInterval(chunks: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_anchor_interval",
                                      payload: SanaStreaming.SetAnchorIntervalParams(chunks: chunks))
    }

    func start() async throws { try await startRun() }

    func pause() async throws {
        try ensureReady()
        try await reactor.sendCommand("pause")
    }

    func resume() async throws {
        try ensureReady()
        try await reactor.sendCommand("resume")
    }

    func reset() async throws { try await resetRun() }

    // ─────────────────────────────────────────────────────────────────
    // Typed callbacks (SANA-Streaming specific)
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    func onChunkComplete(
        _ handler: @escaping @MainActor (SanaStreaming.ChunkCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    func onAnchored(
        _ handler: @escaping @MainActor (SanaStreaming.AnchoredMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .anchored(let a) = msg { handler(a) } }
    }

    @discardableResult
    func onGenerationComplete(
        _ handler: @escaping @MainActor (SanaStreaming.GenerationCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .generationComplete(let g) = msg { handler(g) } }
    }
}
