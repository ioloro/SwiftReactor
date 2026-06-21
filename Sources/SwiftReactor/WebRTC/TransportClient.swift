import Foundation

/// Protocol the Reactor class talks to. The default ``WebRTCTransport``
/// implementation lives in a separate file and depends on the WebRTC
/// xcframework. A no-op implementation is provided here so the rest of
/// the package compiles and can be exercised by tests without binary
/// dependencies.
public protocol ReactorTransport: Actor {
    var status: TransportStatus { get }

    /// Stream of decoded data-channel application + runtime messages.
    nonisolated var messages: AsyncStream<TransportMessage> { get }

    /// Stream of transport-level events (status changes, track arrivals).
    nonisolated var events: AsyncStream<TransportEvent> { get }

    func prepare(tracks: [TrackCapability]) async throws
    func connect(reconnect: Bool, presetConnectionId: Int?) async throws
    func disconnect() async
    func sendCommand(_ command: String, data: AnyCodable, scope: MessageScope, uploads: [String: AnyCodable]?) async throws
    func pauseTrack(_ name: String) async
    func resumeTrack(_ name: String) async
}

public struct TransportMessage: Sendable {
    public let scope: MessageScope
    public let payload: AnyCodable
}

public enum TransportEvent: Sendable {
    case statusChanged(TransportStatus)
    case trackReceived(name: String, track: TransportVideoTrack)
    case error(ReactorError)
}

/// Opaque handle to an incoming video track. The default WebRTC
/// implementation will replace this with a concrete `RTCVideoTrack`
/// wrapper. Kept abstract here so the higher layers remain
/// transport-agnostic.
public protocol TransportVideoTrack: Sendable {
    var name: String { get }
}

/// Stub transport used until the WebRTC.xcframework dependency is wired in.
/// Any call that would touch a peer connection throws ``ReactorError`` with
/// code `TRANSPORT_NOT_IMPLEMENTED`.
public actor StubTransport: ReactorTransport {
    public var status: TransportStatus = .disconnected

    private let messagesContinuation: AsyncStream<TransportMessage>.Continuation
    public nonisolated let messages: AsyncStream<TransportMessage>

    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    public init() {
        (self.messages, self.messagesContinuation) = AsyncStream.makeStream(of: TransportMessage.self)
        (self.events, self.eventsContinuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    public func prepare(tracks: [TrackCapability]) async throws {
        throw notImplemented("prepare")
    }

    public func connect(reconnect: Bool, presetConnectionId: Int?) async throws {
        throw notImplemented("connect")
    }

    public func disconnect() async {
        status = .disconnected
        eventsContinuation.yield(.statusChanged(.disconnected))
    }

    public func sendCommand(_ command: String, data: AnyCodable, scope: MessageScope, uploads: [String: AnyCodable]?) async throws {
        throw notImplemented("sendCommand")
    }

    public func pauseTrack(_ name: String) async {}
    public func resumeTrack(_ name: String) async {}

    private func notImplemented(_ method: String) -> ReactorError {
        ReactorError(
            code: "TRANSPORT_NOT_IMPLEMENTED",
            message: "StubTransport does not implement \(method). Add the WebRTC dependency and use WebRTCTransport.",
            component: .gpu,
            recoverable: false
        )
    }
}
