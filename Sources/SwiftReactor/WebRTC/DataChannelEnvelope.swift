import Foundation

public enum MessageScope: String, Codable, Sendable {
    case application
    case runtime
}

/// Outer envelope for the default ("data") channel.
/// Wire format: `{ "scope": "application" | "runtime", "data": { "type": <command>, "data": <payload>, "uploads"?: ... } }`
struct DataChannelEnvelope: Codable {
    let scope: MessageScope
    let data: Inner

    struct Inner: Codable {
        let type: String
        let data: AnyCodable
        let uploads: [String: AnyCodable]?
    }
}

/// Control-channel message types.
/// Notifications and requests are sent client→server; responses come server→client.
enum ControlMessage {
    struct Notification: Codable {
        let type: String  // always "notification"
        let event: String
        let data: AnyCodable
    }

    struct Request: Codable {
        let type: String  // always "request"
        let method: String
        let requestId: String
        let data: AnyCodable

        enum CodingKeys: String, CodingKey {
            case type, method, data
            case requestId = "request_id"
        }
    }

    struct Response: Codable {
        struct Failure: Codable { let message: String? }
        let type: String  // always "response"
        let requestId: String?
        let method: String?
        let error: Failure?

        enum CodingKeys: String, CodingKey {
            case type, method, error
            case requestId = "request_id"
        }
    }
}

enum EnvelopeEncoder {
    static func encodeCommand(
        _ command: String,
        data: AnyCodable,
        scope: MessageScope,
        uploads: [String: AnyCodable]?
    ) throws -> Data {
        let envelope = DataChannelEnvelope(
            scope: scope,
            data: .init(type: command, data: data, uploads: uploads)
        )
        return try JSONEncoder.reactor.encode(envelope)
    }

    static func encodeControlNotification(event: String, data: AnyCodable) throws -> Data {
        let n = ControlMessage.Notification(type: "notification", event: event, data: data)
        return try JSONEncoder.reactor.encode(n)
    }

    static func encodeControlRequest(method: String, requestId: String, data: AnyCodable) throws -> Data {
        let r = ControlMessage.Request(type: "request", method: method, requestId: requestId, data: data)
        return try JSONEncoder.reactor.encode(r)
    }
}
