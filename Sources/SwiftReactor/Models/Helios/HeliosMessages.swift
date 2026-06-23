import Foundation

public extension Helios {

    /// Typed view of an incoming Helios message. Decoded from the raw
    /// `{type, data: {...}}` wire envelope. Unknown types land in
    /// `.unknown` for forward compatibility.
    enum Message: Sendable {
        case state(StateMessage)
        case promptAccepted(PromptAcceptedMessage)
        case imageAccepted(ImageAcceptedMessage)
        case conditionsReady(ConditionsReadyMessage)
        case generationStarted(GenerationStartedMessage)
        case chunkComplete(ChunkCompleteMessage)
        case generationPaused
        case generationResumed
        case generationReset
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
            case .generationReset: return "generation_reset"
            case .commandError: return "command_error"
            case .unknown(let type, _): return type
            }
        }
    }

    /// Observable snapshot of Helios session state. Emitted on connect,
    /// after every state-mutating command, and after each chunk.
    struct StateMessage: Decodable, Sendable, Equatable {
        public let running: Bool
        public let started: Bool
        public let paused: Bool
        /// Reference image has been set and decoded. Required (with a
        /// prompt at chunk 0) before `start`.
        public let imageSet: Bool
        /// Cumulative chunks since `start`; drives `schedule_prompt` timing.
        public let currentChunk: Int
        public let currentFrame: Int
        public let currentPrompt: String?
        public let imageStrength: Double
        /// Scheduled prompts pending at future chunk indices.
        public let scheduledPrompts: [ScheduledPrompt]
    }

    /// One entry of `state.scheduled_prompts`.
    struct ScheduledPrompt: Decodable, Sendable, Equatable {
        public let prompt: String
        public let chunk: Int
    }

    /// Emitted when `set_prompt` is accepted.
    struct PromptAcceptedMessage: Decodable, Sendable, Equatable {
        public let prompt: String
    }

    /// Emitted when `set_image` finishes decoding.
    struct ImageAcceptedMessage: Decodable, Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// Readiness check: emitted after every `set_prompt` / `set_image`
    /// so the client knows whether `start` will be accepted.
    struct ConditionsReadyMessage: Decodable, Sendable, Equatable {
        public let hasPrompt: Bool
        public let hasImage: Bool
    }

    /// Emitted once when `start` is accepted.
    struct GenerationStartedMessage: Decodable, Sendable, Equatable {
        public let prompt: String
        public let chunkIndex: Int
    }

    /// Emitted once per completed chunk of `main_video`.
    struct ChunkCompleteMessage: Decodable, Sendable, Equatable {
        public let chunkIndex: Int
        public let framesEmitted: Int
        public let activePrompt: String
    }

    /// Emitted when a command is rejected (empty prompt, past chunk,
    /// missing reference image at `start`, etc.).
    struct CommandErrorMessage: Decodable, Sendable, Equatable {
        public let reason: String
        public let command: String
    }
}

extension Helios.Message {

    /// Decode from the raw application-message payload that arrives at
    /// `Reactor.onMessage`. The payload is the inner envelope
    /// `{type, data: {...}}`.
    static func decode(from payload: AnyCodable) -> Helios.Message? {
        guard let dict = payload.value as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        let dataDict = dict["data"] as? [String: Any] ?? [:]
        return decode(type: type, data: dataDict)
    }

    static func decode(type: String, data: [String: Any]) -> Helios.Message {
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
            return tryDecode(Helios.StateMessage.self).map { .state($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "prompt_accepted":
            return tryDecode(Helios.PromptAcceptedMessage.self).map { .promptAccepted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "image_accepted":
            return tryDecode(Helios.ImageAcceptedMessage.self).map { .imageAccepted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "conditions_ready":
            return tryDecode(Helios.ConditionsReadyMessage.self).map { .conditionsReady($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "generation_started":
            return tryDecode(Helios.GenerationStartedMessage.self).map { .generationStarted($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "chunk_complete":
            return tryDecode(Helios.ChunkCompleteMessage.self).map { .chunkComplete($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        case "command_error":
            return tryDecode(Helios.CommandErrorMessage.self).map { .commandError($0) }
                ?? .unknown(type: type, data: AnyCodable(data))
        default:
            return .unknown(type: type, data: AnyCodable(data))
        }
    }
}
