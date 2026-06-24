import Foundation

public extension LongLiveV2 {

    /// Typed view of an incoming LongLive-v2 message. Decoded from the
    /// raw wire envelope (`{type, data: {...}}`) the transport hands to
    /// `Reactor.onMessage`. Anything the SDK doesn't know about lands in
    /// `.unknown` rather than throwing — forward compatibility with
    /// future server messages.
    enum Message: Sendable {
        case state(StateMessage)
        case commandError(CommandErrorMessage)
        case shotSet(ShotSetMessage)
        case sceneCut(SceneCutMessage)
        case chunkComplete(ChunkCompleteMessage)
        case shotScheduled(ShotScheduledMessage)
        case sceneCutScheduled(SceneCutScheduledMessage)
        case generationStarted(GenerationStartedMessage)
        case generationPaused
        case generationResumed
        case generationReset
        case generationComplete(GenerationCompleteMessage)
        case unknown(type: String, data: AnyCodable)

        /// Wire-level message type string (`"state"`, `"command_error"`,
        /// etc.). Useful for routing and debug logging.
        public var type: String {
            switch self {
            case .state: return "state"
            case .commandError: return "command_error"
            case .shotSet: return "shot_set"
            case .sceneCut: return "scene_cut"
            case .chunkComplete: return "chunk_complete"
            case .shotScheduled: return "shot_scheduled"
            case .sceneCutScheduled: return "scene_cut_scheduled"
            case .generationStarted: return "generation_started"
            case .generationPaused: return "generation_paused"
            case .generationResumed: return "generation_resumed"
            case .generationReset: return "generation_reset"
            case .generationComplete: return "generation_complete"
            case .unknown(let type, _): return type
            }
        }
    }

    /// Snapshot of the session's observable state. Emitted on connect,
    /// after every state-mutating event, and after each completed chunk.
    /// Treat as the single source of truth for live position — don't
    /// reconstruct from the event stream.
    struct StateMessage: Decodable, Sendable, Equatable {
        public let seed: Int
        public let paused: Bool
        public let running: Bool
        public let started: Bool
        public let hasPrompt: Bool
        /// Per-scene chunk index. Restarts at 0 after every `scene_cut`.
        /// Scene auto-completes at 48 chunks (~58s).
        public let currentChunk: Int
        public let currentFrame: Int
        /// Session-wide chunk count since the last `start`. Schedule
        /// `schedule_shot` / `schedule_scene_cut` against this.
        public let sessionChunk: Int
        public let currentPrompt: String?
        public let scheduledShots: [Int]
        public let scheduledSceneCuts: [Int]
    }

    /// Emitted when a command is rejected because preconditions aren't
    /// met (empty prompt, wrong state, past chunk, etc.).
    struct CommandErrorMessage: Decodable, Sendable, Equatable {
        public let reason: String
        public let command: String
    }

    /// Emitted when `set_shot` is accepted.
    struct ShotSetMessage: Decodable, Sendable, Equatable {
        public let prompt: String
    }

    /// Emitted when a hard `scene_cut` fires (immediate or scheduled).
    struct SceneCutMessage: Decodable, Sendable, Equatable {
        public let prompt: String
        public let atSessionChunk: Int
    }

    /// Emitted once per completed chunk of `main_video`.
    struct ChunkCompleteMessage: Decodable, Sendable, Equatable {
        public let chunkIndex: Int
        public let activePrompt: String
        public let sessionChunk: Int
        public let framesEmitted: Int
    }

    /// Emitted when `schedule_shot` is accepted.
    struct ShotScheduledMessage: Decodable, Sendable, Equatable {
        public let prompt: String
        public let atSessionChunk: Int
    }

    /// Emitted when `schedule_scene_cut` is accepted.
    struct SceneCutScheduledMessage: Decodable, Sendable, Equatable {
        public let prompt: String
        public let atSessionChunk: Int
    }

    /// Emitted once when `start` is accepted. The `frameNum` field is
    /// the total pixel-frame budget the run will emit.
    struct GenerationStartedMessage: Decodable, Sendable, Equatable {
        public let frameNum: Int
    }

    /// Emitted when every chunk of a run has streamed. The session
    /// returns to idle (`started=false`) and is **locked**: every
    /// command (including `set_shot`) rejects with `command_error`
    /// until the client calls `reset`. `ReactorSession<LongLiveV2>`
    /// handles this automatically when `autoResetOnComplete` is true
    /// (default).
    struct GenerationCompleteMessage: Decodable, Sendable, Equatable {
        public let totalChunks: Int
    }
}

extension LongLiveV2.Message {

    /// Decode from the raw application-message payload that arrives at
    /// `Reactor.onMessage`. The payload is the inner envelope
    /// `{type, data: {...}}`; this dispatches on `type` and decodes the
    /// `data` blob into the strongly-typed sub-message.
    static func decode(from payload: AnyCodable) -> LongLiveV2.Message? {
        guard let dict = payload.value as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        let dataDict = dict["data"] as? [String: Any] ?? [:]
        return decode(type: type, data: dataDict)
    }

    static func decode(type: String, data: [String: Any]) -> LongLiveV2.Message {
        // Some events carry no payload (generation_paused, etc.); we
        // still want to surface those.
        switch type {
        case "generation_paused": return .generationPaused
        case "generation_resumed": return .generationResumed
        case "generation_reset": return .generationReset
        default: break
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
            return .unknown(type: type, data: AnyCodable(data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        func tryDecode<T: Decodable>(_ t: T.Type) -> T? {
            try? decoder.decode(t, from: jsonData)
        }

        switch type {
        case "state":
            return tryDecode(LongLiveV2.StateMessage.self).map { .state($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "command_error":
            return tryDecode(LongLiveV2.CommandErrorMessage.self).map { .commandError($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "shot_set":
            return tryDecode(LongLiveV2.ShotSetMessage.self).map { .shotSet($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "scene_cut":
            return tryDecode(LongLiveV2.SceneCutMessage.self).map { .sceneCut($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "chunk_complete":
            return tryDecode(LongLiveV2.ChunkCompleteMessage.self).map { .chunkComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "shot_scheduled":
            return tryDecode(LongLiveV2.ShotScheduledMessage.self).map { .shotScheduled($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "scene_cut_scheduled":
            return tryDecode(LongLiveV2.SceneCutScheduledMessage.self).map { .sceneCutScheduled($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_started":
            return tryDecode(LongLiveV2.GenerationStartedMessage.self).map { .generationStarted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_complete":
            return tryDecode(LongLiveV2.GenerationCompleteMessage.self).map { .generationComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        default:
            return .unknown(type: type, data: AnyCodable(data))
        }
    }
}
