import Foundation

public extension SanaStreaming {

    enum Message: Sendable {
        case state(StateMessage)
        case promptAccepted(PromptAcceptedMessage)
        case videoAccepted(VideoAcceptedMessage)
        case conditionsReady(ConditionsReadyMessage)
        case generationStarted(GenerationStartedMessage)
        case chunkComplete(ChunkCompleteMessage)
        /// Re-grounding occurred. Emitted every `anchorInterval` chunks
        /// (unless disabled via `set_anchor_interval(0)`).
        case anchored(AnchoredMessage)
        case generationPaused
        case generationResumed
        case generationComplete(GenerationCompleteMessage)
        case generationReset
        case commandError(CommandErrorMessage)
        case unknown(type: String, data: AnyCodable)

        public var type: String {
            switch self {
            case .state: return "state"
            case .promptAccepted: return "prompt_accepted"
            case .videoAccepted: return "video_accepted"
            case .conditionsReady: return "conditions_ready"
            case .generationStarted: return "generation_started"
            case .chunkComplete: return "chunk_complete"
            case .anchored: return "anchored"
            case .generationPaused: return "generation_paused"
            case .generationResumed: return "generation_resumed"
            case .generationComplete: return "generation_complete"
            case .generationReset: return "generation_reset"
            case .commandError: return "command_error"
            case .unknown(let type, _): return type
            }
        }
    }

    /// Observable session snapshot.
    struct StateMessage: Decodable, Sendable, Equatable {
        public let running: Bool
        public let started: Bool
        public let paused: Bool
        public let mode: String
        public let currentChunk: Int
        public let currentPrompt: String?
        public let hasVideo: Bool
        public let hasPrompt: Bool
        public let seed: Int?
        public let anchorInterval: Int
    }

    struct PromptAcceptedMessage: Decodable, Sendable, Equatable {
        public let prompt: String
    }

    struct VideoAcceptedMessage: Decodable, Sendable, Equatable {
        public let durationSeconds: Double?
        public let frameCount: Int?
    }

    struct ConditionsReadyMessage: Decodable, Sendable, Equatable {
        public let hasPrompt: Bool
        public let hasVideo: Bool
    }

    struct GenerationStartedMessage: Decodable, Sendable, Equatable {
        public let prompt: String
        public let chunkIndex: Int
    }

    struct ChunkCompleteMessage: Decodable, Sendable, Equatable {
        public let chunkIndex: Int
        public let framesEmitted: Int
        public let activePrompt: String
    }

    struct AnchoredMessage: Decodable, Sendable, Equatable {
        public let chunkIndex: Int
    }

    struct GenerationCompleteMessage: Decodable, Sendable, Equatable {
        public let totalChunks: Int
    }

    struct CommandErrorMessage: Decodable, Sendable, Equatable {
        public let reason: String
        public let command: String
    }
}

extension SanaStreaming.Message {

    static func decode(from payload: AnyCodable) -> SanaStreaming.Message? {
        guard let dict = payload.value as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        let dataDict = dict["data"] as? [String: Any] ?? [:]
        return decode(type: type, data: dataDict)
    }

    static func decode(type: String, data: [String: Any]) -> SanaStreaming.Message {
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
            return tryDecode(SanaStreaming.StateMessage.self).map { .state($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "prompt_accepted":
            return tryDecode(SanaStreaming.PromptAcceptedMessage.self).map { .promptAccepted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "video_accepted":
            return tryDecode(SanaStreaming.VideoAcceptedMessage.self).map { .videoAccepted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "conditions_ready":
            return tryDecode(SanaStreaming.ConditionsReadyMessage.self).map { .conditionsReady($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_started":
            return tryDecode(SanaStreaming.GenerationStartedMessage.self).map { .generationStarted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "chunk_complete":
            return tryDecode(SanaStreaming.ChunkCompleteMessage.self).map { .chunkComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "anchored":
            return tryDecode(SanaStreaming.AnchoredMessage.self).map { .anchored($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_complete":
            return tryDecode(SanaStreaming.GenerationCompleteMessage.self).map { .generationComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "command_error":
            return tryDecode(SanaStreaming.CommandErrorMessage.self).map { .commandError($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        default:
            return .unknown(type: type, data: AnyCodable(data))
        }
    }
}
