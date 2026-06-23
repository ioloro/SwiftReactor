import Foundation
import Testing
@testable import SwiftReactor
@testable import SwiftReactorDemoSupport

/// Regression suite for the preflight-gate helpers in the demo.
///
/// The bug these tests guard against: caching `conditions_ready` event
/// flags in `@State` and trusting them across a
/// `generation_complete + auto-reset` cycle. After auto-reset the
/// server has cleared its `hasImage` / `hasPrompt`, but a cached flag
/// stays `true` — so the preflight UI claimed "ready to start" while
/// the server was about to emit `[start] No image set`. The
/// `PreflightGates` helpers must always derive their answers from the
/// live snapshot.
@Suite("Preflight gates: snapshot-derived, never stale")
struct PreflightGatesTests {

    // ─────────────────────────────────────────────────────────────────
    // LongLive-v2
    // ─────────────────────────────────────────────────────────────────

    @Test("LongLive: nil snapshot → not ready")
    func longLiveNilSnapshot() {
        #expect(PreflightGates.longLiveOpenerReady(snapshot: nil) == false)
    }

    @Test("LongLive: hasPrompt=false → not ready")
    func longLiveNoPrompt() {
        let s = longLiveState(hasPrompt: false)
        #expect(PreflightGates.longLiveOpenerReady(snapshot: s) == false)
    }

    @Test("LongLive: hasPrompt=true → ready")
    func longLiveHasPrompt() {
        let s = longLiveState(hasPrompt: true)
        #expect(PreflightGates.longLiveOpenerReady(snapshot: s) == true)
    }

    @Test("LongLive: post-(auto-)reset snapshot flips back to not ready")
    func longLivePostAutoReset() {
        // Before generation_complete: server reports hasPrompt=true,
        // gate is true. After auto-reset the server clears hasPrompt
        // and pushes a fresh state; the gate must follow — caching a
        // local `hasSentSetShot=true` would lie here and let `start`
        // ship into `[start] No prompt set`.
        let pre = longLiveState(hasPrompt: true)
        #expect(PreflightGates.longLiveOpenerReady(snapshot: pre) == true)
        let post = longLiveState(hasPrompt: false)
        #expect(PreflightGates.longLiveOpenerReady(snapshot: post) == false,
                "After auto-reset the gate must derive from the new snapshot, not stick on `true`.")
    }

    // ─────────────────────────────────────────────────────────────────
    // Helios
    // ─────────────────────────────────────────────────────────────────

    @Test("Helios: nil snapshot → not ready")
    func heliosNilSnapshot() {
        #expect(PreflightGates.heliosConditionsReady(snapshot: nil) == false)
    }

    @Test("Helios: imageSet but no prompt → not ready")
    func heliosImageOnly() {
        let s = heliosState(imageSet: true, prompt: nil)
        #expect(PreflightGates.heliosConditionsReady(snapshot: s) == false)
    }

    @Test("Helios: prompt but no image → not ready")
    func heliosPromptOnly() {
        let s = heliosState(imageSet: false, prompt: "a sunset")
        #expect(PreflightGates.heliosConditionsReady(snapshot: s) == false)
    }

    @Test("Helios: whitespace-only prompt counts as empty")
    func heliosWhitespacePrompt() {
        let s = heliosState(imageSet: true, prompt: "   \n  ")
        #expect(PreflightGates.heliosConditionsReady(snapshot: s) == false)
    }

    @Test("Helios: imageSet AND non-empty prompt → ready")
    func heliosBothSet() {
        let s = heliosState(imageSet: true, prompt: "a sunset")
        #expect(PreflightGates.heliosConditionsReady(snapshot: s) == true)
    }

    @Test("Helios: post-reset snapshot (imageSet=false) flips back to not ready")
    func heliosPostReset() {
        let pre = heliosState(imageSet: true, prompt: "a sunset")
        #expect(PreflightGates.heliosConditionsReady(snapshot: pre) == true)
        let post = heliosState(imageSet: false, prompt: nil)
        #expect(PreflightGates.heliosConditionsReady(snapshot: post) == false,
                "After server-side reset, the gate must derive from the new snapshot, not stick on the prior 'ready'.")
    }

    // ─────────────────────────────────────────────────────────────────
    // LingBot
    // ─────────────────────────────────────────────────────────────────

    @Test("LingBot: nil snapshot → not ready")
    func lingBotNilSnapshot() {
        #expect(PreflightGates.lingBotConditionsReady(snapshot: nil) == false)
    }

    @Test("LingBot: only one of has_prompt / has_image → not ready")
    func lingBotPartial() {
        #expect(PreflightGates.lingBotConditionsReady(snapshot: lingBotState(hasPrompt: true, hasImage: false)) == false)
        #expect(PreflightGates.lingBotConditionsReady(snapshot: lingBotState(hasPrompt: false, hasImage: true)) == false)
    }

    @Test("LingBot: both set → ready")
    func lingBotBothSet() {
        #expect(PreflightGates.lingBotConditionsReady(snapshot: lingBotState(hasPrompt: true, hasImage: true)) == true)
    }

    @Test("LingBot: post-reset snapshot flips back to not ready")
    func lingBotPostReset() {
        let pre = lingBotState(hasPrompt: true, hasImage: true)
        #expect(PreflightGates.lingBotConditionsReady(snapshot: pre) == true)
        let post = lingBotState(hasPrompt: false, hasImage: false)
        #expect(PreflightGates.lingBotConditionsReady(snapshot: post) == false,
                "After auto-reset clears server state, the gate must follow — this is the exact bug the screenshot caught.")
    }

    // ─────────────────────────────────────────────────────────────────
    // SANA-Streaming
    // ─────────────────────────────────────────────────────────────────

    @Test("SANA: nil snapshot → neither ready nor mode-set")
    func sanaNilSnapshot() {
        #expect(PreflightGates.sanaConditionsReady(snapshot: nil) == false)
        #expect(PreflightGates.sanaModeSet(snapshot: nil) == false)
    }

    @Test("SANA: mode == file → modeSet true")
    func sanaModeSet() {
        let s = sanaState(mode: "file", hasVideo: false, hasPrompt: false)
        #expect(PreflightGates.sanaModeSet(snapshot: s) == true)
    }

    @Test("SANA: mode == live → modeSet false (live not yet ready in v0.2)")
    func sanaModeLive() {
        let s = sanaState(mode: "live", hasVideo: false, hasPrompt: false)
        #expect(PreflightGates.sanaModeSet(snapshot: s) == false)
    }

    @Test("SANA: file mode plus hasVideo + hasPrompt → ready")
    func sanaReady() {
        let s = sanaState(mode: "file", hasVideo: true, hasPrompt: true)
        #expect(PreflightGates.sanaConditionsReady(snapshot: s) == true)
    }

    @Test("SANA: post-reset snapshot clears both gates")
    func sanaPostReset() {
        let pre = sanaState(mode: "file", hasVideo: true, hasPrompt: true)
        #expect(PreflightGates.sanaConditionsReady(snapshot: pre) == true)
        #expect(PreflightGates.sanaModeSet(snapshot: pre) == true)
        let post = sanaState(mode: "", hasVideo: false, hasPrompt: false)
        #expect(PreflightGates.sanaConditionsReady(snapshot: post) == false)
        #expect(PreflightGates.sanaModeSet(snapshot: post) == false)
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    private func longLiveState(hasPrompt: Bool) -> LongLiveV2.StateMessage {
        decode(LongLiveV2.StateMessage.self, from: [
            "seed": 42,
            "paused": false,
            "running": false,
            "started": false,
            "has_prompt": hasPrompt,
            "current_chunk": 0,
            "current_frame": 0,
            "session_chunk": 0,
            "current_prompt": NSNull(),
            "scheduled_shots": [Int](),
            "scheduled_scene_cuts": [Int](),
        ])
    }

    private func heliosState(imageSet: Bool, prompt: String?) -> Helios.StateMessage {
        decode(Helios.StateMessage.self, from: [
            "running": false,
            "started": false,
            "paused": false,
            "image_set": imageSet,
            "current_chunk": 0,
            "current_frame": 0,
            "current_prompt": prompt as Any,
            "image_strength": 0.5,
            "scheduled_prompts": [[String: Any]](),
        ])
    }

    private func lingBotState(hasPrompt: Bool, hasImage: Bool) -> LingBot.StateMessage {
        decode(LingBot.StateMessage.self, from: [
            "running": false,
            "started": false,
            "paused": false,
            "current_chunk": 0,
            "current_prompt": NSNull(),
            "has_prompt": hasPrompt,
            "has_image": hasImage,
            "current_action": "still",
            "movement": "idle",
            "look_horizontal": "idle",
            "look_vertical": "idle",
            "rotation_speed_deg": 5.0,
            "seed": 42,
        ])
    }

    private func sanaState(mode: String, hasVideo: Bool, hasPrompt: Bool) -> SanaStreaming.StateMessage {
        decode(SanaStreaming.StateMessage.self, from: [
            "running": false,
            "started": false,
            "paused": false,
            "mode": mode,
            "current_chunk": 0,
            "current_prompt": NSNull(),
            "has_video": hasVideo,
            "has_prompt": hasPrompt,
            "seed": NSNull(),
            "anchor_interval": 20,
        ])
    }

    /// Round-trip via `JSONSerialization` + camelCase-converting decoder so the
    /// test exercises the same wire shape the SDK's message decoder sees.
    private func decode<T: Decodable>(_ type: T.Type, from dict: [String: Any]) -> T {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(T.self, from: data)
    }
}
