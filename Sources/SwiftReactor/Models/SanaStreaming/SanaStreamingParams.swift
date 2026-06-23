import Foundation

/// Typed command parameters for the SANA-Streaming model — real-time
/// **video-to-video editing**. Mirrors the wire schema at
/// `https://docs.reactor.inc/model-api-reference/sana-streaming/schema`.
///
/// Specialty: input video. Choose ``Mode/live`` to push frames from a
/// local camera (sendonly track, currently a SwiftReactor v0.2 stub) or
/// ``Mode/file`` to point at a pre-uploaded clip via ``setVideo(_:)``.
/// The model emits 24-frame chunks every ~1–1.5s at 1280×704.
public enum SanaStreaming {

    /// Input source for the editing pipeline.
    public enum Mode: String, Encodable, Sendable, Equatable, CaseIterable {
        /// Local camera streamed via a sendonly `camera` track. Requires
        /// `publishTrack` on the transport — currently a SwiftReactor
        /// v0.2 stub; track this in the v0.3 milestone.
        case live
        /// Pre-uploaded clip via ``SanaStreamingSession/setVideo(_:)``.
        /// File mode auto-completes when the clip's last frame ships.
        case file
    }

    /// Parameters for `set_mode`.
    public struct SetModeParams: Encodable, Sendable, Equatable {
        public let mode: Mode
        public init(_ mode: Mode) { self.mode = mode }
    }

    /// Parameters for `set_video`. File mode only. The `FileRef` comes
    /// from ``Reactor/uploadFile(data:name:mimeType:)``.
    public struct SetVideoParams: Encodable, Sendable, Equatable {
        public let video: FileRef
        public init(video: FileRef) { self.video = video }
    }

    /// Parameters for `set_prompt`. Editing instruction; mid-run changes
    /// take effect at the next chunk boundary.
    public struct SetPromptParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public init(prompt: String) { self.prompt = prompt }
    }

    /// Parameters for `set_seed`.
    public struct SetSeedParams: Encodable, Sendable, Equatable {
        public let seed: Int
        public init(seed: Int) { self.seed = seed }
    }

    /// Parameters for `set_anchor_interval`. Re-grounding cadence — the
    /// model re-references the source every `chunks` chunks. `0`
    /// disables re-anchoring; default `20`. Lower values keep edits
    /// faithful but cost coherence; higher values let the model drift.
    public struct SetAnchorIntervalParams: Encodable, Sendable, Equatable {
        public let chunks: Int
        public init(chunks: Int) { self.chunks = chunks }
    }
}
