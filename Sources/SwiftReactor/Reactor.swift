import Foundation
import Observation

/// Top-level entry point. Mirrors the JS SDK's `Reactor` class.
///
/// Lifecycle: ``connect(jwt:)`` → wait for `status == .ready` → ``sendCommand(_:payload:scope:)`` → ``disconnect()``.
@MainActor
@Observable
public final class Reactor {
    public private(set) var status: ReactorStatus = .disconnected
    public private(set) var lastError: ReactorError?
    public private(set) var sessionId: String?
    public private(set) var capabilities: Capabilities?

    public let configuration: ReactorConfiguration

    private let urlSession: URLSession
    private let transportFactory: @Sendable (ReactorConfiguration, JWTSource, String) -> any ReactorTransport

    private var coordinator: CoordinatorClient?
    private var transport: (any ReactorTransport)?
    private var jwt: JWTSource?
    private var eventTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var autoResumeTracks = true
    private var tracks: [TrackCapability] = []
    private var createdSession = false

    private let eventsContinuation: AsyncStream<ReactorEvent>.Continuation
    public nonisolated let events: AsyncStream<ReactorEvent>
    let callbackRegistry = CallbackRegistry()

    public init(
        configuration: ReactorConfiguration,
        urlSession: URLSession = .shared,
        transportFactory: @escaping @Sendable (ReactorConfiguration, JWTSource, String) -> any ReactorTransport = { config, jwt, sessionId in
            WebRTCTransport(configuration: config, jwt: jwt, sessionId: sessionId)
        }
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.transportFactory = transportFactory
        (self.events, self.eventsContinuation) = AsyncStream.makeStream(of: ReactorEvent.self)
    }

    public convenience init(
        modelName: String,
        baseURL: URL = ReactorConfiguration.productionBaseURL
    ) {
        self.init(configuration: ReactorConfiguration(modelName: modelName, baseURL: baseURL))
    }

    // ─────────────────────────────────────────────────────────────────────
    // Connection lifecycle
    // ─────────────────────────────────────────────────────────────────────

    public func connect(jwt: JWTSource, autoResumeTracks: Bool = true) async throws {
        guard status == .disconnected else {
            throw ReactorError(code: "ALREADY_CONNECTED", message: "Reactor is already connecting or connected.", component: .api, recoverable: false)
        }
        self.jwt = jwt
        self.autoResumeTracks = autoResumeTracks
        setStatus(.connecting)

        do {
            let coordinator = CoordinatorClient(configuration: configuration, jwt: jwt, urlSession: urlSession)
            self.coordinator = coordinator

            let initial = try await coordinator.createSession()
            createdSession = true
            sessionId = initial.sessionId
            setStatus(.waiting)

            let session = try await coordinator.pollSessionReady()
            guard let caps = session.capabilities,
                  let transportDecl = session.selectedTransport else {
                throw ReactorError(code: "MISSING_CAPABILITIES", message: "Session ready but capabilities or selected_transport missing.", component: .api, recoverable: false)
            }
            guard transportDecl.protocol == "webrtc" else {
                throw ReactorError(code: "UNSUPPORTED_TRANSPORT", message: "Unsupported transport protocol: \(transportDecl.protocol)", component: .api, recoverable: false)
            }
            capabilities = caps
            tracks = caps.tracks
            emit(.capabilitiesReceived(caps))

            let transport = transportFactory(configuration, jwt, initial.sessionId)
            self.transport = transport
            subscribeToTransport(transport)

            try await transport.prepare(tracks: tracks)
            try await transport.connect(reconnect: false, presetConnectionId: nil)
        } catch {
            await disconnectInternal(recoverable: false)
            let reactorError = (error as? ReactorError) ?? ReactorError(
                code: "CONNECTION_FAILED",
                message: "\(error)",
                component: .api,
                recoverable: true
            )
            recordError(reactorError)
            throw reactorError
        }
    }

    public func disconnect(recoverable: Bool = false) async {
        await disconnectInternal(recoverable: recoverable)
    }

    /// Reconnect with the JWT used in the last ``connect(jwt:autoResumeTracks:)`` call.
    /// Mirrors Python `reactor.reconnect()`. Throws if no prior session was established.
    public func reconnect() async throws {
        guard let jwt else {
            throw ReactorError(
                code: "NO_PRIOR_SESSION",
                message: "Cannot reconnect without a prior connect() call.",
                component: .api,
                recoverable: false
            )
        }
        if status == .ready { return }
        // Force a full disconnect so connect() preconditions are met.
        await disconnectInternal(recoverable: false)
        try await connect(jwt: jwt, autoResumeTracks: autoResumeTracks)
    }

    private func disconnectInternal(recoverable: Bool) async {
        eventTask?.cancel(); eventTask = nil
        messageTask?.cancel(); messageTask = nil

        if let transport {
            await transport.disconnect()
        }

        if let coordinator, createdSession, !recoverable {
            try? await coordinator.terminateSession()
        }

        if !recoverable {
            transport = nil
            coordinator = nil
            sessionId = nil
            capabilities = nil
            tracks = []
            createdSession = false
            jwt = nil
        }
        setStatus(.disconnected)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Commands
    // ─────────────────────────────────────────────────────────────────────

    /// Send a command to the model once `status == .ready`.
    ///
    /// `payload` is anything `Encodable` (a `[String: Any]`-like dict, a
    /// nested struct, etc.). It's serialized as the `data` field inside
    /// the application envelope.
    public func sendCommand(
        _ command: String,
        payload: any Encodable & Sendable = EmptyPayload(),
        scope: MessageScope = .application
    ) async throws {
        guard status == .ready else {
            throw ReactorError(
                code: "NOT_READY",
                message: "Cannot send command \"\(command)\" while status is \(status). Must be .ready.",
                component: .api,
                recoverable: true
            )
        }
        guard let transport else {
            throw ReactorError(code: "NO_TRANSPORT", message: "Transport not initialized.", component: .api, recoverable: false)
        }
        let encoded = try JSONEncoder.reactor.encode(AnyEncodable(payload))
        let asAny = try JSONDecoder.reactor.decode(AnyCodable.self, from: encoded)
        try await transport.sendCommand(command, data: asAny, scope: scope, uploads: nil)
    }

    // ─────────────────────────────────────────────────────────────────────
    // File uploads
    // ─────────────────────────────────────────────────────────────────────

    /// Reserve a presigned upload URL with the coordinator and PUT
    /// `data` to it. The returned ``FileRef`` is what you hand to
    /// commands that consume files (Helios `set_image`, LingBot
    /// `set_image`, SANA-Streaming `set_video`).
    ///
    /// Requires `status == .ready`; presigned URLs expire after about
    /// 15 minutes so use the returned `FileRef` promptly.
    public func uploadFile(data: Data, name: String, mimeType: String) async throws -> FileRef {
        guard status == .ready else {
            throw ReactorError(
                code: "NOT_READY",
                message: "Cannot upload while status is \(status). Must be .ready.",
                component: .api,
                recoverable: true
            )
        }
        guard let coordinator else {
            throw ReactorError(
                code: "NO_COORDINATOR",
                message: "uploadFile called before coordinator was wired.",
                component: .api,
                recoverable: false
            )
        }
        let presigned = try await coordinator.uploadFile(data: data, name: name, mimeType: mimeType)
        return FileRef(
            uploadId: presigned.presignedId,
            name: name,
            mimeType: mimeType,
            size: data.count
        )
    }

    // ─────────────────────────────────────────────────────────────────────
    // Testing
    // ─────────────────────────────────────────────────────────────────────

    /// Skip the coordinator handshake and wire `Reactor` directly to
    /// an injected transport (typically a `MockTransport`). Used by
    /// unit tests to exercise the public surface — `sendCommand`,
    /// `onMessage`, status flow — without a real backend.
    ///
    /// The transport drives the status machine the same way it would
    /// in production: emit `.statusChanged(.connected)` and `Reactor`
    /// flips to `.ready`. Marked `@_spi(Testing)` so it stays out of
    /// the day-to-day public surface; opt-in with
    /// `@_spi(Testing) import SwiftReactor`.
    @_spi(Testing) public func connectForTesting(transport: any ReactorTransport) {
        guard status == .disconnected else { return }
        self.transport = transport
        subscribeToTransport(transport)
        sessionId = "test-session"
        setStatus(.waiting)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Wiring
    // ─────────────────────────────────────────────────────────────────────

    private func subscribeToTransport(_ transport: any ReactorTransport) {
        let events = transport.events
        let messages = transport.messages
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(transportEvent: event)
            }
        }
        messageTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                self.handle(message: message)
            }
        }
    }

    private func handle(transportEvent: TransportEvent) {
        switch transportEvent {
        case .statusChanged(let status):
            switch status {
            case .connected:
                if autoResumeTracks {
                    for track in tracks where track.direction == .recvonly {
                        Task { [weak self] in
                            await self?.transport?.resumeTrack(track.name)
                        }
                    }
                }
                setStatus(.ready)
            case .disconnected:
                Task { [weak self] in await self?.disconnectInternal(recoverable: true) }
            case .error:
                let err = ReactorError(code: "TRANSPORT_ERROR", message: "Transport reported error.", component: .gpu, recoverable: true)
                recordError(err)
                Task { [weak self] in await self?.disconnectInternal(recoverable: false) }
            case .connecting:
                break
            }
        case .trackReceived(let name, let track):
            emit(.trackReceived(name: name, track: track))
        case .error(let err):
            recordError(err)
        }
    }

    private func handle(message: TransportMessage) {
        switch message.scope {
        case .application:
            emit(.message(message.payload))
        case .runtime:
            emit(.runtimeMessage(message.payload))
        }
    }

    private func setStatus(_ newStatus: ReactorStatus) {
        guard status != newStatus else { return }
        status = newStatus
        emit(.statusChanged(newStatus))
    }

    private func recordError(_ error: ReactorError) {
        lastError = error
        emit(.error(error))
    }

    /// Single fan-out point: yields to the AsyncStream and calls every
    /// callback registered via ``on(_:_:)`` for the matching event family.
    private func emit(_ event: ReactorEvent) {
        eventsContinuation.yield(event)
        callbackRegistry.dispatch(event)
    }
}

public enum ReactorEvent: Sendable {
    case statusChanged(ReactorStatus)
    case capabilitiesReceived(Capabilities)
    case trackReceived(name: String, track: any TransportVideoTrack)
    case message(AnyCodable)
    case runtimeMessage(AnyCodable)
    case error(ReactorError)
}

public struct EmptyPayload: Codable, Sendable {
    public init() {}
}
