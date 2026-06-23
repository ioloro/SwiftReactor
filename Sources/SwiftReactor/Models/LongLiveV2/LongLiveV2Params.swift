import Foundation

/// Typed command parameters for the LongLive-v2 model.
///
/// Mirrors the parameter shapes documented in
/// `@reactor-models/longlive-v2`. The snake_case property names are the
/// literal wire keys the server expects — renaming any of them silently
/// breaks the wire contract (the original `at_session_chunk` bug we hit
/// in Sunnyside was exactly this: sending `session_chunk` defaults the
/// server's `at_session_chunk` to `-1`, which never fires).
///
/// These structs are also the *only* sanctioned way to call LongLive
/// commands from Swift — going through `Reactor.sendCommand("...",
/// payload: …)` with a dict is supported, but you give up compile-time
/// key safety.
public enum LongLiveV2 {

    /// Parameters for `set_shot`. Before `start`, seeds the opening
    /// shot. After `start`, drives a soft shot change at the next chunk
    /// boundary — same world, memory preserved.
    public struct SetShotParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public init(prompt: String) { self.prompt = prompt }
    }

    /// Parameters for `scene_cut`. Hard break to a new scene at the next
    /// chunk boundary — model memory wiped, the per-scene 48-chunk
    /// budget resets, the session-wide `session_chunk` keeps counting.
    public struct SceneCutParams: Encodable, Sendable, Equatable {
        public let prompt: String
        public init(prompt: String) { self.prompt = prompt }
    }

    /// Parameters for `schedule_shot`. Soft shot change planted ahead of
    /// time, fires when `session_chunk` reaches `at_session_chunk`.
    public struct ScheduleShotParams: Encodable, Sendable, Equatable {
        public let prompt: String
        // swiftlint:disable:next identifier_name
        public let at_session_chunk: Int
        public init(prompt: String, atSessionChunk: Int) {
            self.prompt = prompt
            self.at_session_chunk = atSessionChunk
        }
    }

    /// Parameters for `schedule_scene_cut`. Hard scene cut planted ahead
    /// of time, fires when `session_chunk` reaches `at_session_chunk`.
    public struct ScheduleSceneCutParams: Encodable, Sendable, Equatable {
        public let prompt: String
        // swiftlint:disable:next identifier_name
        public let at_session_chunk: Int
        public init(prompt: String, atSessionChunk: Int) {
            self.prompt = prompt
            self.at_session_chunk = atSessionChunk
        }
    }

    /// Parameters for `set_seed`. Read once when `start` fires; later
    /// changes only take effect after `reset` followed by a new `start`.
    public struct SetSeedParams: Encodable, Sendable, Equatable {
        public let seed: Int
        public init(seed: Int) { self.seed = seed }
    }
}
