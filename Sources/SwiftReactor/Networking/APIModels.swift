import Foundation

public enum SessionState: String, Codable, Sendable {
    case created = "CREATED"
    case pending = "PENDING"
    case suspended = "SUSPENDED"
    case waiting = "WAITING"
    case active = "ACTIVE"
    case inactive = "INACTIVE"
    case closed = "CLOSED"
}

public enum TrackKind: String, Codable, Sendable {
    case video, audio
}

public enum TrackDirection: String, Codable, Sendable {
    case recvonly, sendonly
}

public struct TrackCapability: Codable, Sendable, Equatable {
    public let name: String
    public let kind: TrackKind
    public let direction: TrackDirection
}

public struct TrackMappingEntry: Codable, Sendable {
    public let mid: String
    public let name: String
    public let kind: TrackKind
    public let direction: TrackDirection
}

public struct CommandCapability: Codable, Sendable {
    public let name: String
    public let description: String
    public let schema: [String: AnyCodable]?
}

public struct Capabilities: Codable, Sendable {
    public let protocolVersion: String
    public let tracks: [TrackCapability]
    public let commands: [CommandCapability]?
    public let emissionFPS: Double?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case tracks
        case commands
        case emissionFPS = "emission_fps"
    }
}

public struct TransportDeclaration: Codable, Sendable {
    public let `protocol`: String
    public let version: String
}

struct ClientInfo: Codable, Sendable {
    let sdkVersion: String
    let sdkType: String

    enum CodingKeys: String, CodingKey {
        case sdkVersion = "sdk_version"
        case sdkType = "sdk_type"
    }
}

struct CreateSessionRequest: Codable {
    struct Model: Codable { let name: String }
    let model: Model
    let clientInfo: ClientInfo
    let supportedTransports: [TransportDeclaration]
    let extraArgs: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case model
        case clientInfo = "client_info"
        case supportedTransports = "supported_transports"
        case extraArgs = "extra_args"
    }
}

public struct SessionInfoResponse: Codable, Sendable {
    public let sessionId: String
    public let state: String
    public let cluster: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, cluster
    }
}

public struct CreateSessionResponse: Codable, Sendable {
    public struct Model: Codable, Sendable {
        public let name: String
        public let version: String?
    }
    public struct ServerInfo: Codable, Sendable {
        public let serverVersion: String
        enum CodingKeys: String, CodingKey { case serverVersion = "server_version" }
    }
    public let sessionId: String
    public let state: String
    public let cluster: String
    public let model: Model
    public let serverInfo: ServerInfo

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, cluster, model
        case serverInfo = "server_info"
    }
}

public struct SessionResponse: Codable, Sendable {
    public let sessionId: String
    public let state: String
    public let cluster: String
    public let model: CreateSessionResponse.Model
    public let serverInfo: CreateSessionResponse.ServerInfo
    public let selectedTransport: TransportDeclaration?
    public let capabilities: Capabilities?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state, cluster, model
        case serverInfo = "server_info"
        case selectedTransport = "selected_transport"
        case capabilities
    }
}

struct TerminateSessionRequest: Codable {
    let reason: String?
}

struct CreateUploadRequest: Codable {
    let name: String
    let size: Int
    let mimeType: String

    enum CodingKeys: String, CodingKey {
        case name, size
        case mimeType = "mime_type"
    }
}

public struct CreateUploadResponse: Codable, Sendable {
    public let presignedId: String
    public let presignedURL: URL
    public let path: String

    enum CodingKeys: String, CodingKey {
        case presignedId = "presigned_id"
        case presignedURL = "presigned_url"
        case path
    }
}

public struct IceServer: Codable, Sendable {
    public struct Credentials: Codable, Sendable {
        public let username: String
        public let password: String
    }
    public let uris: [String]
    public let credentials: Credentials?
}

public struct IceServersResponse: Codable, Sendable {
    public let iceServers: [IceServer]

    enum CodingKeys: String, CodingKey {
        case iceServers = "ice_servers"
    }
}

struct WebRTCSdpOfferRequest: Codable {
    let sdpOffer: String
    let clientInfo: ClientInfo?
    let trackMapping: [TrackMappingEntry]

    enum CodingKeys: String, CodingKey {
        case sdpOffer = "sdp_offer"
        case clientInfo = "client_info"
        case trackMapping = "track_mapping"
    }
}

struct WebRTCSdpOfferResponse: Codable {
    let connectionId: Int?

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
    }
}

struct WebRTCSdpAnswerResponse: Codable {
    let sdpAnswer: String
    let connectionId: Int?

    enum CodingKeys: String, CodingKey {
        case sdpAnswer = "sdp_answer"
        case connectionId = "connection_id"
    }
}

public struct IceCandidate: Codable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int?

    enum CodingKeys: String, CodingKey {
        case candidate
        case sdpMid = "sdp_mid"
        case sdpMLineIndex = "sdp_mline_index"
    }

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int?) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

struct IceCandidatesRequest: Codable {
    let candidates: [IceCandidate]
    let isFinal: Bool
    let clientInfo: ClientInfo?

    enum CodingKeys: String, CodingKey {
        case candidates
        case isFinal = "is_final"
        case clientInfo = "client_info"
    }
}

public struct ConnectionRegistration: Codable, Sendable {
    public let connectionId: Int

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
    }
}
