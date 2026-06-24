import Foundation

/// Helios command surface on ``ReactorSession``. Only available
/// when `Model == Helios`; calling these on a session of any other
/// model is a compile-time error.
public extension ReactorSession where Model == Helios {

    // ─────────────────────────────────────────────────────────────────
    // Convenience: image upload
    // ─────────────────────────────────────────────────────────────────

    /// Upload a reference image. Convenience for the common Helios
    /// pattern of `uploadFile` → `setImage`; for atomic prompt+image
    /// updates use ``setConditioning(prompt:image:)``.
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

    /// Send `set_prompt`. Before `start`, seeds chunk 0; after
    /// `start`, applies at the next chunk boundary.
    func setPrompt(_ prompt: String) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_prompt",
                                      payload: Helios.SetPromptParams(prompt: prompt))
    }

    /// Send `schedule_prompt`. Apply `prompt` exactly at cumulative
    /// chunk `chunk`. Past chunks are rejected during active
    /// generation.
    func schedulePrompt(_ prompt: String, atChunk chunk: Int) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "schedule_prompt",
            payload: Helios.SchedulePromptParams(prompt: prompt, chunk: chunk)
        )
    }

    /// Send `set_image`. Sets or swaps the reference image used for
    /// conditioning.
    func setImage(_ image: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_image",
                                      payload: Helios.SetImageParams(image: image))
    }

    /// Send `set_conditioning`. Atomically updates prompt +
    /// reference image — prefer this over sequential `setPrompt` +
    /// `setImage` when both change together.
    func setConditioning(prompt: String, image: FileRef) async throws {
        try ensureReady()
        try await reactor.sendCommand(
            "set_conditioning",
            payload: Helios.SetConditioningParams(prompt: prompt, image: image)
        )
    }

    /// Send `set_image_strength`. Range `0.0...1.0`; doesn't apply
    /// until the next `set_image` / `set_conditioning` (or after
    /// `reset`).
    func setImageStrength(_ strength: Double) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_image_strength",
                                      payload: Helios.SetImageStrengthParams(strength: strength))
    }

    /// Send `set_sr_scale`. Off / 2x / 4x super-resolution upscaling.
    func setSRScale(_ scale: Helios.SRScale) async throws {
        try ensureReady()
        try await reactor.sendCommand("set_sr_scale",
                                      payload: Helios.SetSRScaleParams(scale: scale))
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
                                      payload: Helios.SetSeedParams(seed: seed))
    }

    // ─────────────────────────────────────────────────────────────────
    // Typed callbacks (Helios specific)
    // ─────────────────────────────────────────────────────────────────

    @discardableResult
    func onChunkComplete(
        _ handler: @escaping @MainActor (Helios.ChunkCompleteMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .chunkComplete(let c) = msg { handler(c) } }
    }

    @discardableResult
    func onConditionsReady(
        _ handler: @escaping @MainActor (Helios.ConditionsReadyMessage) -> Void
    ) -> UUID {
        onMessage { msg in if case .conditionsReady(let c) = msg { handler(c) } }
    }
}
