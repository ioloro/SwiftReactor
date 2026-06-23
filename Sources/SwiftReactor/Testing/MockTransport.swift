import Foundation

/// Test-only `ReactorTransport` that records outbound commands and lets
/// the test inject inbound messages and status transitions.
///
/// Wire it into `Reactor` via the `transportFactory` initializer:
/// ```swift
/// let mock = MockTransport()
/// let reactor = Reactor(
///     configuration: .init(modelName: "longlive-v2"),
///     transportFactory: { _, _, _ in mock }
/// )
/// ```
/// Then `await mock.simulateReady()` to skip the WebRTC handshake, and
/// `mock.sentCommands` to assert what the consumer wrote.
///
/// Lives in the package itself (not the test target) so applications
/// can also use it in their own unit tests without a binary dependency
/// on the WebRTC.framework.
public actor MockTransport: ReactorTransport {

    public struct RecordedCommand: Sendable {
        public let command: String
        public let data: AnyCodable
        public let scope: MessageScope

        public init(command: String, data: AnyCodable, scope: MessageScope) {
            self.command = command
            self.data = data
            self.scope = scope
        }
    }

    public private(set) var status: TransportStatus = .disconnected
    public private(set) var preparedTracks: [TrackCapability] = []
    public private(set) var sentCommands: [RecordedCommand] = []
    public private(set) var resumedTracks: [String] = []
    public private(set) var pausedTracks: [String] = []

    private let messagesContinuation: AsyncStream<TransportMessage>.Continuation
    public nonisolated let messages: AsyncStream<TransportMessage>

    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation
    public nonisolated let events: AsyncStream<TransportEvent>

    public init() {
        (self.messages, self.messagesContinuation) = AsyncStream.makeStream(of: TransportMessage.self)
        (self.events, self.eventsContinuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    // MARK: ReactorTransport

    public func prepare(tracks: [TrackCapability]) async throws {
        preparedTracks = tracks
    }

    public func connect(reconnect: Bool, presetConnectionId: Int?) async throws {
        status = .connecting
        eventsContinuation.yield(.statusChanged(.connecting))
    }

    public func disconnect() async {
        status = .disconnected
        eventsContinuation.yield(.statusChanged(.disconnected))
    }

    public func sendCommand(_ command: String, data: AnyCodable, scope: MessageScope, uploads: [String: AnyCodable]?) async throws {
        sentCommands.append(RecordedCommand(command: command, data: data, scope: scope))
    }

    public func pauseTrack(_ name: String) async {
        pausedTracks.append(name)
    }

    public func resumeTrack(_ name: String) async {
        resumedTracks.append(name)
    }

    // MARK: Test helpers

    /// Flip the transport to `connected`, which `Reactor` translates
    /// into `status == .ready`. Skips the full WebRTC handshake.
    public func simulateReady() {
        status = .connected
        eventsContinuation.yield(.statusChanged(.connected))
    }

    public func simulateDisconnected() {
        status = .disconnected
        eventsContinuation.yield(.statusChanged(.disconnected))
    }

    /// Inject a typed application message (the inner `{type, data}`
    /// envelope) as if the server had sent it.
    public func simulateApplicationMessage(_ payload: [String: Any]) {
        messagesContinuation.yield(TransportMessage(scope: .application,
                                                    payload: AnyCodable(payload)))
    }

    /// Convenience for LongLive-v2 message simulation: wraps your
    /// fields in `{type, data: {...}}` as the wire envelope expects.
    public func simulateLongLiveMessage(type: String, data: [String: Any] = [:]) {
        simulateApplicationMessage(["type": type, "data": data])
    }

    /// Clear recorded commands (handy between assertions in a single
    /// test).
    public func resetRecording() {
        sentCommands.removeAll()
        resumedTracks.removeAll()
        pausedTracks.removeAll()
    }
}
