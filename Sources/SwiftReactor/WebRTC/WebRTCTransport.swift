import Foundation
import OSLog
@preconcurrency import WebRTC

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "webrtc")

/// Concrete ``ReactorTransport`` implementation using Google's WebRTC stack
/// (vendored as `stasel/WebRTC`). Owns the peer connection, the `"data"` and
/// `"control"` data channels, the transceivers declared in capabilities, and
/// the HTTP signaling client.
///
/// v1 scope: connect, render server-emitted recvonly tracks (e.g.
/// `main_video`), send application commands. Pause/resume via SDP
/// renegotiation and `publishTrack` (sendonly tracks like a live camera
/// feed) are still stubs. File uploads go through
/// ``Reactor/uploadFile(data:name:mimeType:)`` and the coordinator's
/// presigned-URL flow, not this transport.
public actor WebRTCTransport: ReactorTransport {
    public private(set) var status: TransportStatus = .disconnected

    public nonisolated let messages: AsyncStream<TransportMessage>
    public nonisolated let events: AsyncStream<TransportEvent>
    private let messagesContinuation: AsyncStream<TransportMessage>.Continuation
    private let eventsContinuation: AsyncStream<TransportEvent>.Continuation

    private let signaling: TransportSignalingClient
    private let configuration: ReactorConfiguration

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()

    private var peerConnection: RTCPeerConnection?
    private var delegateProxy: PeerConnectionDelegateProxy?
    private var dataChannel: RTCDataChannel?
    private var controlChannel: RTCDataChannel?
    private var dataChannelDelegate: DataChannelDelegateProxy?
    private var controlChannelDelegate: DataChannelDelegateProxy?

    private var connectionId: Int?
    private var transceivers: [String: (entry: TrackCapability, transceiver: RTCRtpTransceiver)] = [:]

    private var peerConnected = false
    private var dataChannelOpen = false
    private var controlChannelOpen = false
    private var pingTask: Task<Void, Never>?

    /// Interval between client→server keepalive pings on the runtime data
    /// channel. Reactor's server closes the session after ~25s of silence,
    /// and may withhold RTP entirely without these. Matches the JS SDK's
    /// `PING_INTERVAL_MS = 5_000`.
    private static let pingIntervalNanoseconds: UInt64 = 5_000_000_000

    public init(
        configuration: ReactorConfiguration,
        jwt: JWTSource,
        sessionId: String,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.signaling = TransportSignalingClient(
            configuration: configuration,
            jwt: jwt,
            sessionId: sessionId,
            urlSession: urlSession
        )
        (self.messages, self.messagesContinuation) = AsyncStream.makeStream(of: TransportMessage.self)
        (self.events, self.eventsContinuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    // ─────────────────────────────────────────────────────────────────────
    // ReactorTransport — Connection
    // ─────────────────────────────────────────────────────────────────────

    public func prepare(tracks: [TrackCapability]) async throws {
        log.info("prepare(tracks: \(tracks.map(\.name).joined(separator: ","), privacy: .public))")
        setStatus(.connecting)

        let iceConfig = try await fetchAndBuildICEConfig()
        log.info("ICE servers fetched, count=\(iceConfig.iceServers.count)")

        // Reserve the connection slot before creating the peer connection,
        // so any candidates the peer connection emits during gathering have
        // a connectionId to post against. Without this the first burst of
        // host/srflx candidates is dropped and ICE never converges.
        if self.connectionId == nil {
            self.connectionId = try await signaling.registerConnection()
            log.info("registered connectionId=\(self.connectionId ?? -1)")
        }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let delegate = PeerConnectionDelegateProxy(owner: self)
        self.delegateProxy = delegate
        guard let pc = Self.factory.peerConnection(with: iceConfig, constraints: constraints, delegate: delegate) else {
            throw ReactorError(code: "PC_CREATE_FAILED", message: "Failed to create RTCPeerConnection.", component: .gpu, recoverable: false)
        }
        self.peerConnection = pc

        // Control channel BEFORE the data channel. The JS SDK preserves this
        // ordering so older runtimes that collapse channels last-write-wins
        // onto a single internal handle land on the main data channel.
        if let control = pc.dataChannel(forLabel: "control", configuration: RTCDataChannelConfiguration()) {
            self.controlChannel = control
            let proxy = DataChannelDelegateProxy(owner: self, kind: .control)
            self.controlChannelDelegate = proxy
            control.delegate = proxy
        }
        if let data = pc.dataChannel(forLabel: "data", configuration: RTCDataChannelConfiguration()) {
            self.dataChannel = data
            let proxy = DataChannelDelegateProxy(owner: self, kind: .data)
            self.dataChannelDelegate = proxy
            data.delegate = proxy
        }

        // Add transceivers so the SDP offer carries m= sections for every
        // capability track. MIDs are assigned after createOffer +
        // setLocalDescription, so trackMapping is built *after* that.
        transceivers.removeAll()
        for track in tracks {
            let init_ = RTCRtpTransceiverInit()
            init_.direction = track.direction.rtcDirection
            let kind: RTCRtpMediaType = track.kind == .video ? .video : .audio
            guard let t = pc.addTransceiver(of: kind, init: init_) else {
                throw ReactorError(
                    code: "TRANSCEIVER_ADD_FAILED",
                    message: "Failed to add transceiver for \(track.name).",
                    component: .gpu,
                    recoverable: false
                )
            }
            transceivers[track.name] = (track, t)
        }
    }

    public func connect(reconnect: Bool, presetConnectionId: Int?) async throws {
        guard let pc = peerConnection else {
            throw ReactorError(code: "NO_PEER_CONNECTION", message: "Call prepare() before connect().", component: .gpu, recoverable: false)
        }

        let offer = try await pc.offer(for: .init(mandatoryConstraints: nil, optionalConstraints: nil))
        try await pc.setLocalDescription(offer)

        let connectionId: Int
        if let presetConnectionId {
            connectionId = presetConnectionId
            self.connectionId = connectionId
        } else if let existing = self.connectionId {
            // Already reserved in prepare() so ICE candidates could trickle.
            connectionId = existing
        } else {
            connectionId = try await signaling.registerConnection()
            self.connectionId = connectionId
        }

        let mapping = buildTrackMapping()
        try await signaling.sendSdpOffer(
            connectionId: connectionId,
            sdpOffer: offer.sdp,
            trackMapping: mapping,
            reconnect: reconnect
        )
        let answerSDP = try await signaling.pollSdpAnswer(connectionId: connectionId)
        log.info("SDP answer received (\(answerSDP.count) bytes):\n\(answerSDP, privacy: .public)")
        let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
        try await pc.setRemoteDescription(answer)
        log.info("setRemoteDescription succeeded; waiting for ICE + data-channel readiness")
    }

    public func disconnect() async {
        stopPing()
        peerConnection?.close()
        peerConnection = nil
        delegateProxy = nil
        dataChannel = nil
        controlChannel = nil
        dataChannelDelegate = nil
        controlChannelDelegate = nil
        transceivers.removeAll()
        connectionId = nil
        peerConnected = false
        dataChannelOpen = false
        controlChannelOpen = false
        setStatus(.disconnected)
    }

    private func startPing() {
        stopPing()
        let pingPayload: Data
        do {
            pingPayload = try EnvelopeEncoder.encodeCommand(
                "ping",
                data: AnyCodable([String: AnyCodable]()),
                scope: .runtime,
                uploads: nil
            )
        } catch {
            log.error("failed to encode ping payload: \(String(describing: error), privacy: .public)")
            return
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.sendPing(payload: pingPayload)
            }
        }
    }

    private func stopPing() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func sendPing(payload: Data) {
        guard let channel = dataChannel, channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: payload, isBinary: false))
    }

    // ─────────────────────────────────────────────────────────────────────
    // ReactorTransport — Messaging
    // ─────────────────────────────────────────────────────────────────────

    public func sendCommand(
        _ command: String,
        data: AnyCodable,
        scope: MessageScope,
        uploads: [String: AnyCodable]?
    ) async throws {
        guard let channel = dataChannel, channel.readyState == .open else {
            throw ReactorError(
                code: "DATA_CHANNEL_NOT_OPEN",
                message: "Cannot send command \"\(command)\": data channel is not open.",
                component: .gpu,
                recoverable: true
            )
        }
        let payload = try EnvelopeEncoder.encodeCommand(command, data: data, scope: scope, uploads: uploads)
        let buffer = RTCDataBuffer(data: payload, isBinary: false)
        channel.sendData(buffer)
    }

    public func pauseTrack(_ name: String) async {
        // SDP renegotiation deferred. Send the notification so the server
        // stops the RTP flow; client-side direction stays as-was.
        sendControlNotification(event: "pause_track", data: ["name": name])
    }

    public func resumeTrack(_ name: String) async {
        // The server doesn't start RTP on a recvonly transceiver until it
        // sees this notification. Without it the track sits attached but
        // empty — frames are generated but never transmitted.
        sendControlNotification(event: "resume_track", data: ["name": name])
    }

    private func sendControlNotification(event: String, data: [String: String]) {
        guard let channel = controlChannel, channel.readyState == .open else {
            log.warning("control channel not open, dropping \(event, privacy: .public)")
            return
        }
        do {
            let payload = try EnvelopeEncoder.encodeControlNotification(
                event: event,
                data: AnyCodable(data)
            )
            channel.sendData(RTCDataBuffer(data: payload, isBinary: false))
            log.info("sent control notification: \(event, privacy: .public) \(data)")
        } catch {
            log.error("failed to encode control notification \(event, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Delegate bridge — methods on the actor surface for the proxies to call
    // ─────────────────────────────────────────────────────────────────────

    func didReceiveICECandidate(_ candidate: RTCIceCandidate) async {
        guard let connectionId else {
            log.warning("ICE candidate generated but no connectionId yet: \(candidate.sdp, privacy: .public)")
            return
        }
        log.info("trickle ICE candidate: \(candidate.sdp, privacy: .public)")
        let entry = IceCandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )
        do {
            try await signaling.sendIceCandidates(connectionId: connectionId, candidates: [entry], isFinal: false)
        } catch {
            log.error("ICE candidate POST failed: \(String(describing: error), privacy: .public)")
        }
    }

    func didFinishGatheringICE() async {
        guard let connectionId else {
            log.warning("ICE gathering complete but no connectionId yet")
            return
        }
        log.info("ICE gathering complete; sending final-flag POST")
        do {
            try await signaling.sendIceCandidates(connectionId: connectionId, candidates: [], isFinal: true)
        } catch {
            log.error("ICE final-flag POST failed: \(String(describing: error), privacy: .public)")
        }
    }

    func didChangePeerConnectionState(_ state: RTCPeerConnectionState) async {
        switch state {
        case .connected:
            peerConnected = true
            updateConnectedStatus()
        case .disconnected, .closed:
            peerConnected = false
            setStatus(.disconnected)
        case .failed:
            peerConnected = false
            setStatus(.error)
            eventsContinuation.yield(.error(ReactorError(
                code: "PC_CONNECTION_FAILED",
                message: "RTCPeerConnection entered failed state.",
                component: .gpu,
                recoverable: true
            )))
        default:
            break
        }
    }

    func didReceiveTrack(_ transceiver: RTCRtpTransceiver, track: RTCMediaStreamTrack) {
        let name = transceivers.first(where: { $0.value.transceiver.mid == transceiver.mid })?.key
            ?? transceiver.mid
        log.info("didStartReceivingOn fired, mid=\(transceiver.mid, privacy: .public) name=\(name, privacy: .public) trackKind=\(track.kind, privacy: .public)")
        if let videoTrack = track as? RTCVideoTrack {
            let handle = WebRTCVideoTrackHandle(name: name, track: videoTrack)
            eventsContinuation.yield(.trackReceived(name: name, track: handle))
        }
    }

    /// Unified-Plan callback that fires when a receiver becomes active, often
    /// earlier than `didStartReceivingOn`. The mid may not be assigned yet, so
    /// we fall back to the transceiver lookup by receiver identity.
    func didAddReceiver(_ receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = receiver.track else {
            log.info("didAddReceiver: receiver had no track (id=\(receiver.receiverId, privacy: .public))")
            return
        }
        let name = transceivers.first(where: { $0.value.transceiver.receiver.receiverId == receiver.receiverId })?.key
            ?? streams.first?.streamId
            ?? "unknown"
        log.info("didAddReceiver fired, name=\(name, privacy: .public) streams=\(streams.count) trackKind=\(track.kind, privacy: .public)")
        if let videoTrack = track as? RTCVideoTrack {
            let handle = WebRTCVideoTrackHandle(name: name, track: videoTrack)
            eventsContinuation.yield(.trackReceived(name: name, track: handle))
        }
    }

    func didChangeDataChannelState(kind: ChannelKind, state: RTCDataChannelState) {
        switch kind {
        case .data:
            dataChannelOpen = (state == .open)
        case .control:
            controlChannelOpen = (state == .open)
        }
        if state == .open {
            updateConnectedStatus()
        }
    }

    func didReceiveDataMessage(kind: ChannelKind, data: Data) {
        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary \(data.count)B>"
        log.info("data channel msg (\(kind == .data ? "data" : "control", privacy: .public), \(data.count, privacy: .public)B): \(preview, privacy: .public)")
        switch kind {
        case .data:
            handleApplicationMessage(data)
        case .control:
            // Control channel responses aren't surfaced in v1.
            break
        }
    }

    private func handleApplicationMessage(_ data: Data) {
        struct Envelope: Decodable {
            let scope: MessageScope?
            let data: AnyCodable
        }
        guard let envelope = try? JSONDecoder.reactor.decode(Envelope.self, from: data) else { return }
        messagesContinuation.yield(TransportMessage(
            scope: envelope.scope ?? .application,
            payload: envelope.data
        ))
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    private func fetchAndBuildICEConfig() async throws -> RTCConfiguration {
        let response = try await signaling.fetchIceServers()
        let config = RTCConfiguration()
        config.iceServers = response.iceServers.map { server in
            if let creds = server.credentials {
                return RTCIceServer(urlStrings: server.uris, username: creds.username, credential: creds.password)
            } else {
                return RTCIceServer(urlStrings: server.uris)
            }
        }
        config.sdpSemantics = .unifiedPlan
        return config
    }

    private func buildTrackMapping() -> [TrackMappingEntry] {
        transceivers.compactMap { name, pair in
            let mid = pair.transceiver.mid
            guard !mid.isEmpty else { return nil }
            return TrackMappingEntry(
                mid: mid,
                name: name,
                kind: pair.entry.kind,
                direction: pair.entry.direction
            )
        }
    }

    private func updateConnectedStatus() {
        if peerConnected && dataChannelOpen && controlChannelOpen && status != .connected {
            setStatus(.connected)
            startPing()
        }
    }

    private func setStatus(_ newStatus: TransportStatus) {
        guard status != newStatus else { return }
        status = newStatus
        eventsContinuation.yield(.statusChanged(newStatus))
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Delegate proxies — bridge the synchronous RTC delegate calls into the actor
// ─────────────────────────────────────────────────────────────────────────

enum ChannelKind: Sendable {
    case data, control
}

final class PeerConnectionDelegateProxy: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    weak var owner: WebRTCTransport?
    init(owner: WebRTCTransport) { self.owner = owner }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log.debug("signalingState=\(stateChanged.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        log.info("didAdd stream id=\(stream.streamId, privacy: .public) video=\(stream.videoTracks.count) audio=\(stream.audioTracks.count)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.info("iceConnectionState=\(newState.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log.info("iceGatheringState=\(newState.rawValue)")
        if newState == .complete {
            Task { [weak owner] in await owner?.didFinishGatheringICE() }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { [weak owner] in await owner?.didReceiveICECandidate(candidate) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log.info("server opened data channel label=\(dataChannel.label, privacy: .public)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        log.info("connectionState=\(newState.rawValue)")
        Task { [weak owner] in await owner?.didChangePeerConnectionState(newState) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        let track = transceiver.receiver.track
        if let track {
            Task { [weak owner] in await owner?.didReceiveTrack(transceiver, track: track) }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        nonisolated(unsafe) let receiver = rtpReceiver
        nonisolated(unsafe) let streams = mediaStreams
        Task { [weak owner] in await owner?.didAddReceiver(receiver, streams: streams) }
    }
}

final class DataChannelDelegateProxy: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    weak var owner: WebRTCTransport?
    let kind: ChannelKind
    init(owner: WebRTCTransport, kind: ChannelKind) {
        self.owner = owner
        self.kind = kind
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        let kind = self.kind
        Task { [weak owner] in await owner?.didChangeDataChannelState(kind: kind, state: state) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let kind = self.kind
        let data = buffer.data
        Task { [weak owner] in await owner?.didReceiveDataMessage(kind: kind, data: data) }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Public video track handle + small enum bridge
// ─────────────────────────────────────────────────────────────────────────

public struct WebRTCVideoTrackHandle: TransportVideoTrack, @unchecked Sendable {
    public let name: String
    public let track: RTCVideoTrack
}

extension TrackDirection {
    var rtcDirection: RTCRtpTransceiverDirection {
        switch self {
        case .recvonly: return .recvOnly
        case .sendonly: return .sendOnly
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Continuation bridges for the callback-only RTCPeerConnection APIs
// ─────────────────────────────────────────────────────────────────────────

private extension RTCPeerConnection {
    func offer(for constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            self.offer(for: constraints) { sdp, error in
                if let error { cont.resume(throwing: error) }
                else if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: ReactorError(code: "OFFER_EMPTY", message: "createOffer returned no SDP.", component: .gpu, recoverable: false)) }
            }
        }
    }

    func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
