import Foundation

/// LingBot command surface on ``ReactorSession``. Only available
/// when `Model == LingBot`; calling these on a session of any other
/// model is a compile-time error.
public extension ReactorSession where Model == LingBot {

    // ─────────────────────────────────────────────────────────────────
    // Convenience: image upload
    // ─────────────────────────────────────────────────────────────────

    /// Upload the required seed image. Equivalent to
    /// `reactor.uploadFile(...)`; provided here for ergonomic
    /// discovery.
    func uploadImage(
        data: Data,
        name: String,
        mimeType: String = "image/jpeg"
    ) async throws -> FileRef {
        try await reactor.uploadFile(data: data, name: name, mimeType: mimeType)
    }

    // ─────────────────────────────────────────────────────────────────
    // Commands
    // ─────────────────────────────────────────────────────────────────

    /// Send `set_prompt`. Max ~1000 chars server-side.
    func setPrompt(_ prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_prompt",
                                      payload: LingBot.SetPromptParams(prompt: prompt))
    }

    /// Send `set_image`. Required before `start`.
    func setImage(_ image: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_image",
                                      payload: LingBot.SetImageParams(image: image))
    }

    /// Send `set_movement`. Sticky — model applies this every chunk
    /// until changed.
    func setMovement(_ movement: LingBot.Movement) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_movement",
                                      payload: LingBot.SetMovementParams(movement))
    }

    /// Send `set_look_horizontal`. Sticky yaw control.
    func setLookHorizontal(_ look: LingBot.LookHorizontal) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_look_horizontal",
                                      payload: LingBot.SetLookHorizontalParams(look))
    }

    /// Send `set_look_vertical`. Sticky pitch control.
    func setLookVertical(_ look: LingBot.LookVertical) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_look_vertical",
                                      payload: LingBot.SetLookVerticalParams(look))
    }

    /// Send `set_rotation_speed_deg`. Range `0.0...30.0`. Applies to
    /// both look axes.
    func setRotationSpeed(degreesPerChunk: Double) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "set_rotation_speed_deg",
            payload: LingBot.SetRotationSpeedParams(degreesPerChunk: degreesPerChunk)
        )
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

    func setSeed(_ seed: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_seed",
                                      payload: LingBot.SetSeedParams(seed: seed))
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed callbacks (LingBot specific)
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    func onChunkComplete(
        _ handler: @escaping @MainActor (LingBot.ChunkCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    func onGenerationComplete(
        _ handler: @escaping @MainActor (LingBot.GenerationCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .generationComplete(let g) = msg { handler(g) } }
    }
}
