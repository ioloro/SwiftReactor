import Foundation

public extension LingBot {

    /// Typed view of an incoming LingBot message. Decoded from the raw
    /// `{type, data: {...}}` wire envelope.
    enum Message: Sendable {
        case state(StateMessage)
        case promptAccepted(PromptAcceptedMessage)
        case imageAccepted(ImageAcceptedMessage)
        case conditionsReady(ConditionsReadyMessage)
        case generationStarted(GenerationStartedMessage)
        case chunkComplete(ChunkCompleteMessage)
        case generationPaused
        case generationResumed
        case generationComplete(GenerationCompleteMessage)
        case generationReset(GenerationResetMessage)
        case commandError(CommandErrorMessage)
        case unknown(type: String, data: AnyCodable)

        public var type: String {
            switch self {
            case .state: return "state"
            case .promptAccepted: return "prompt_accepted"
            case .imageAccepted: return "image_accepted"
            case .conditionsReady: return "conditions_ready"
            case .generationStarted: return "generation_started"
            case .chunkComplete: return "chunk_complete"
            case .generationPaused: return "generation_paused"
            case .generationResumed: return "generation_resumed"
            case .generationComplete: return "generation_complete"
            case .generationReset: return "generation_reset"
            case .commandError: return "command_error"
            case .unknown(let type, _): return type
            }
        }
    }

    /// Observable snapshot of LingBot session state. Note `currentAction`
    /// is a `+`-joined string (e.g. `"forward+left"`, or `"still"` when
    /// fully idle) — the model treats it as a single composed input.
    struct StateMessage: Decodable, Sendable, Equatable {
        public let running: Bool
        public let started: Bool
        public let paused: Bool
        /// Zero-based index of last completed chunk.
        public let currentChunk: Int
        public let currentPrompt: String?
        public let hasPrompt: Bool
        public let hasImage: Bool
        /// `+`-joined composite of `movement` + `lookHorizontal` +
        /// `lookVertical`; `"still"` when fully idle.
        public let currentAction: String
        public let movement: String
        public let lookHorizontal: String
        public let lookVertical: String
        public let rotationSpeedDeg: Double
        /// Effective only on the next `start`. Changing mid-run is
        /// accepted but doesn't take effect until `reset` + new `start`.
        public let seed: Int
    }

    struct PromptAcceptedMessage: Decodable, Sendable, Equatable {
        public let prompt: String
    }

    struct ImageAcceptedMessage: Decodable, Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// Readiness check after `set_prompt` / `set_image`. Both must be
    /// true before `start` will succeed.
    struct ConditionsReadyMessage: Decodable, Sendable, Equatable {
        public let hasPrompt: Bool
        public let hasImage: Bool
    }

    struct GenerationStartedMessage: Decodable, Sendable, Equatable {
        public let prompt: String
        public let chunkNum: Int
        public let frameNum: Int
    }

    struct ChunkCompleteMessage: Decodable, Sendable, Equatable {
        public let chunkIndex: Int
        public let framesEmitted: Int
        public let activePrompt: String
        /// Composite action active during this chunk.
        public let activeAction: String
    }

    struct GenerationCompleteMessage: Decodable, Sendable, Equatable {
        public let totalChunks: Int
    }

    struct GenerationResetMessage: Decodable, Sendable, Equatable {
        public let reason: String
    }

    struct CommandErrorMessage: Decodable, Sendable, Equatable {
        public let reason: String
        public let command: String
    }
}

extension LingBot.Message {

    static func decode(from payload: AnyCodable) -> LingBot.Message? {
        guard let dict = payload.value as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        let dataDict = dict["data"] as? [String: Any] ?? [:]
        return decode(type: type, data: dataDict)
    }

    static func decode(type: String, data: [String: Any]) -> LingBot.Message {
        switch type {
        case "generation_paused": return .generationPaused
        case "generation_resumed": return .generationResumed
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
            return tryDecode(LingBot.StateMessage.self).map { .state($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "prompt_accepted":
            return tryDecode(LingBot.PromptAcceptedMessage.self).map { .promptAccepted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "image_accepted":
            return tryDecode(LingBot.ImageAcceptedMessage.self).map { .imageAccepted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "conditions_ready":
            return tryDecode(LingBot.ConditionsReadyMessage.self).map { .conditionsReady($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_started":
            return tryDecode(LingBot.GenerationStartedMessage.self).map { .generationStarted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "chunk_complete":
            return tryDecode(LingBot.ChunkCompleteMessage.self).map { .chunkComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_complete":
            return tryDecode(LingBot.GenerationCompleteMessage.self).map { .generationComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_reset":
            return tryDecode(LingBot.GenerationResetMessage.self).map { .generationReset($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "command_error":
            return tryDecode(LingBot.CommandErrorMessage.self).map { .commandError($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        default:
            return .unknown(type: type, data: AnyCodable(data))
        }
    }
}
