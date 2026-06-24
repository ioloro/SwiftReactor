import Foundation

/// LongLive-v2 command surface on ``ReactorSession``. Only available
/// when `Model == LongLiveV2`; calling these on a session of any
/// other model is a compile-time error, which is the point.
public extension ReactorSession where Model == LongLiveV2 {

    // ─────────────────────────────────────────────────────────────────
    // Commands
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_shot`. Before `start`, seeds the opener; after
    /// `start`, triggers a soft shot change at the next chunk
    /// boundary.
    func setShot(prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_shot",
                                      payload: LongLiveV2.SetShotParams(prompt: prompt))
    }

    /// Send `scene_cut`. Hard break to a new scene — memory wiped,
    /// per-scene 48-chunk budget reset.
    func sceneCut(prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("scene_cut",
                                      payload: LongLiveV2.SceneCutParams(prompt: prompt))
    }

    /// Schedule a soft shot change at an absolute `session_chunk`.
    func scheduleShot(prompt: String, atSessionChunk: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "schedule_shot",
            payload: LongLiveV2.ScheduleShotParams(prompt: prompt, atSessionChunk: atSessionChunk)
        )
    }

    /// Schedule a hard scene cut at an absolute `session_chunk`.
    func scheduleSceneCut(prompt: String, atSessionChunk: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "schedule_scene_cut",
            payload: LongLiveV2.ScheduleSceneCutParams(prompt: prompt, atSessionChunk: atSessionChunk)
        )
    }

    /// Begin generating from the opening shot. Idempotent at the
    /// SDK boundary — a second call while ``hasStartedRun`` throws
    /// ``LongLiveV2/LocalError/alreadyStarted``.
    func start() async throws { try await startRun() }

    func pause() async throws {
        try ensureReady()
        try await reactor.sendCommand("pause")
    }

    func resume() async throws {
        try ensureReady()
        try await reactor.sendCommand("resume")
    }

    /// Abort the current run and clear all scheduled state. After
    /// this, `setShot` then `start` are required before generation.
    func reset() async throws { try await resetRun() }

    func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: LongLiveV2.SetSeedParams(seed: seed))
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed callbacks (LongLive-v2 specific)
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    func onChunkComplete(
        _ handler: @escaping @MainActor (LongLiveV2.ChunkCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in
            if case .chunkComplete(let c) = msg { handler(c) }
        }
    }

    @discardableResult
    func onGenerationComplete(
        _ handler: @escaping @MainActor (LongLiveV2.GenerationCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in
            if case .generationComplete(let g) = msg { handler(g) }
        }
    }
}
