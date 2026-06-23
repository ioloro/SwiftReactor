import Foundation
import SwiftReactor

/// Pure functions for the demo's per-model preflight gates. Kept in
/// the support target (and not inline in the tab files) so they're
/// unit-testable without standing up SwiftUI views.
///
/// The recurring trap these helpers exist to avoid: caching server-ack
/// events (`conditions_ready`, `prompt_accepted`) in `@State` and
/// trusting them across a `generation_complete + auto-reset` cycle.
/// After auto-reset the server has cleared its state but the cached
/// flag stays `true`, so the preflight lies — "everything ready" while
/// the server is about to emit `[start] No image set`. **Always derive
/// gates from the live snapshot**, which is what these helpers do.
public enum PreflightGates {

    // MARK: - LongLive-v2

    /// True when the server snapshot reports a prompt is set — i.e. an
    /// opener `setShot` has been acknowledged by the server. Derived
    /// from the snapshot (not a cached `hasSentSetShot` flag) so that
    /// after `generation_complete + auto-reset`, the gate transparently
    /// flips back to false when the server clears `hasPrompt`. Caching
    /// the flag locally is the exact stale-gate bug we keep hitting.
    public static func longLiveOpenerReady(snapshot: LongLiveV2.StateMessage?) -> Bool {
        snapshot?.hasPrompt ?? false
    }

    // MARK: - Helios

    /// True when the server's snapshot reports both a non-empty current
    /// prompt and a set reference image. Required gate before `start`.
    public static func heliosConditionsReady(snapshot: Helios.StateMessage?) -> Bool {
        guard let s = snapshot else { return false }
        let promptOK = (s.currentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return s.imageSet && promptOK
    }

    // MARK: - LingBot

    /// True when the server's snapshot reports `hasPrompt && hasImage`.
    public static func lingBotConditionsReady(snapshot: LingBot.StateMessage?) -> Bool {
        guard let s = snapshot else { return false }
        return s.hasPrompt && s.hasImage
    }

    // MARK: - SANA-Streaming

    /// True when the server's snapshot reports `hasPrompt && hasVideo`.
    public static func sanaConditionsReady(snapshot: SanaStreaming.StateMessage?) -> Bool {
        guard let s = snapshot else { return false }
        return s.hasPrompt && s.hasVideo
    }

    /// True when the server snapshot reports file mode is set. Derived
    /// rather than cached so `reset` (which clears mode server-side)
    /// transparently flips the gate back off.
    public static func sanaModeSet(snapshot: SanaStreaming.StateMessage?) -> Bool {
        snapshot?.mode == "file"
    }
}
