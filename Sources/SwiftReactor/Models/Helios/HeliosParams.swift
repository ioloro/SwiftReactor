import Foundation

/// Typed command parameters for the Helios model — "interactive
/// real-time video with infinite streaming." Mirrors the wire schema
/// documented at
/// `https://docs.reactor.inc/model-api-reference/helios/schema`.
///
/// Helios uses **chunked autoregressive generation** (33 frames/chunk,
/// ~1.4s at 24fps). Prompts and image conditioning apply at chunk
/// boundaries; `schedule_prompt` plants a change at a specific cumulative
/// chunk index for cinematic timing.
public enum Helios {

    /// Parameters for `set_prompt`. Convenience around
    /// ``SchedulePromptParams`` that auto-picks the right chunk index
    /// (chunk 0 before `start`, "next chunk" after).
    public struct SetPromptParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public init(prompt: String) { self.prompt = prompt }
    }

    /// Parameters for `schedule_prompt`. Apply `prompt` exactly at
    /// cumulative chunk `chunk`. Past chunks are rejected during
    /// active generation.
    public struct SchedulePromptParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public let chunk: Int
        public init(prompt: String, chunk: Int) {
            self.prompt = prompt
            self.chunk = chunk
        }
    }

    /// Parameters for `set_image`. Sets or swaps the reference image
    /// used for conditioning. The server rescales to internal
    /// resolution; aspect ratios outside Helios's training distribution
    /// produce visible compression artifacts.
    public struct SetImageParams: Encodable, Sendable, Equatable {
        public let image: FileRef
        public init(image: FileRef) { self.image = image }
    }

    /// Parameters for `set_conditioning`. Atomically updates the prompt
    /// *and* the reference image in a single message — use this instead
    /// of separate `set_prompt` + `set_image` when both change together,
    /// to avoid a transient frame rendered against mismatched inputs.
    public struct SetConditioningParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public let image: FileRef
        public init(prompt: String, image: FileRef) {
            self.prompt = prompt
            self.image = image
        }
    }

    /// Parameters for `set_image_strength`. Controls how tightly the
    /// model anchors to the reference image — `0.0` ignores the image,
    /// `1.0` reproduces it. Doesn't apply until the next `set_image` /
    /// `set_conditioning` (or a `reset`).
    public struct SetImageStrengthParams: Encodable, Sendable, Equatable {
        // swiftlint:disable:next identifier_name
        public let image_strength: Double
        public init(strength: Double) { self.image_strength = strength }
    }

    /// Super-resolution scale applied to the outbound video.
    /// Helios renders internally at a lower resolution and upscales —
    /// `2x` and `4x` cost extra GPU but ship sharper frames.
    public enum SRScale: String, Encodable, Sendable, Equatable {
        case off
        case x2 = "2x"
        case x4 = "4x"
    }

    /// Parameters for `set_sr_scale`.
    public struct SetSRScaleParams: Encodable, Sendable, Equatable {
        // swiftlint:disable:next identifier_name
        public let sr_scale: SRScale
        public init(scale: SRScale) { self.sr_scale = scale }
    }

    /// Parameters for `set_seed`. Same seed + same prompt sequence
    /// reproduces the same video. Read once on `start`; later changes
    /// require `reset` + new `start`.
    public struct SetSeedParams: Encodable, Sendable, Equatable {
        public let seed: Int
        public init(seed: Int) { self.seed = seed }
    }
}
