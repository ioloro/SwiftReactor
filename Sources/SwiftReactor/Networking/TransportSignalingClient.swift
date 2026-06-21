import Foundation

actor TransportSignalingClient {
    private let configuration: ReactorConfiguration
    private let jwt: JWTSource
    private let sessionId: String
    private let urlSession: URLSession

    private static let initialBackoff: TimeInterval = 0.2
    private static let maxBackoff: TimeInterval = 15.0
    private static let backoffMultiplier: Double = 2.0
    private static let defaultMaxPollAttempts = 6

    init(
        configuration: ReactorConfiguration,
        jwt: JWTSource,
        sessionId: String,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.jwt = jwt
        self.sessionId = sessionId
        self.urlSession = urlSession
    }

    private var transportPath: String {
        "/sessions/\(sessionId)/transport/webrtc"
    }

    func fetchIceServers() async throws -> IceServersResponse {
        try await get(path: "\(transportPath)/ice_servers")
    }

    func registerConnection() async throws -> Int {
        let response: ConnectionRegistration = try await post(
            path: "\(transportPath)/connections",
            body: EmptyBody()
        )
        return response.connectionId
    }

    func sendSdpOffer(
        connectionId: Int,
        sdpOffer: String,
        trackMapping: [TrackMappingEntry],
        reconnect: Bool
    ) async throws {
        let body = WebRTCSdpOfferRequest(
            sdpOffer: sdpOffer,
            clientInfo: ClientInfo(sdkVersion: configuration.sdkVersion, sdkType: "swift"),
            trackMapping: trackMapping
        )
        let path = "\(transportPath)/connections/\(connectionId)/sdp_params"
        let method = reconnect ? "PUT" : "POST"
        try await sendAccepted(path: path, method: method, body: body)
    }

    func pollSdpAnswer(connectionId: Int, maxAttempts: Int = TransportSignalingClient.defaultMaxPollAttempts) async throws -> String {
        let path = "\(transportPath)/connections/\(connectionId)/sdp_params"
        var backoff = Self.initialBackoff
        for attempt in 1...maxAttempts {
            var request = try makeRequest(path: path, method: "GET")
            try await authorize(&request)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ReactorError(code: "HTTP_INVALID_RESPONSE", message: "Non-HTTP response.", component: .gpu, recoverable: false)
            }
            switch http.statusCode {
            case 200:
                let parsed = try JSONDecoder.reactor.decode(WebRTCSdpAnswerResponse.self, from: data)
                return parsed.sdpAnswer
            case 202:
                if attempt == maxAttempts { break }
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * Self.backoffMultiplier, Self.maxBackoff)
                continue
            default:
                let text = String(data: data, encoding: .utf8) ?? ""
                throw ReactorError(
                    code: "HTTP_\(http.statusCode)",
                    message: "SDP answer poll failed: HTTP \(http.statusCode) \(text)",
                    component: .gpu,
                    recoverable: http.statusCode >= 500
                )
            }
        }
        throw ReactorError(
            code: "SDP_POLL_EXHAUSTED",
            message: "SDP answer polling exceeded maxAttempts=\(maxAttempts).",
            component: .gpu,
            recoverable: true
        )
    }

    func sendIceCandidates(connectionId: Int, candidates: [IceCandidate], isFinal: Bool) async throws {
        let body = IceCandidatesRequest(
            candidates: candidates,
            isFinal: isFinal,
            clientInfo: ClientInfo(sdkVersion: configuration.sdkVersion, sdkType: "swift")
        )
        try await sendAccepted(
            path: "\(transportPath)/connections/\(connectionId)/ice_candidates",
            method: "POST",
            body: body
        )
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        var request = try makeRequest(path: path, method: "GET")
        try await authorize(&request)
        let (data, response) = try await urlSession.data(for: request)
        try validate2xx(response, data: data)
        return try JSONDecoder.reactor.decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST", body: body)
        try await authorize(&request)
        let (data, response) = try await urlSession.data(for: request)
        try validate2xx(response, data: data)
        return try JSONDecoder.reactor.decode(Response.self, from: data)
    }

    private func sendAccepted<Body: Encodable>(path: String, method: String, body: Body) async throws {
        var request = try makeRequest(path: path, method: method, body: body)
        try await authorize(&request)
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReactorError(code: "HTTP_INVALID_RESPONSE", message: "Non-HTTP response.", component: .gpu, recoverable: false)
        }
        guard http.statusCode == 202 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ReactorError(
                code: "HTTP_\(http.statusCode)",
                message: "Expected 202 from \(path), got \(http.statusCode): \(text)",
                component: .gpu,
                recoverable: http.statusCode >= 500
            )
        }
    }

    private func makeRequest(path: String, method: String, body: (any Encodable)? = nil) throws -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.webRTCVersion, forHTTPHeaderField: "Reactor-WebRTC-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.reactor.encode(AnyEncodable(body))
        }
        return request
    }

    private func authorize(_ request: inout URLRequest) async throws {
        let token = try await jwt.resolve()
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate2xx(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ReactorError(code: "HTTP_INVALID_RESPONSE", message: "Non-HTTP response.", component: .gpu, recoverable: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ReactorError(
                code: "HTTP_\(http.statusCode)",
                message: "HTTP \(http.statusCode) for \(http.url?.path ?? "?"): \(text)",
                component: .gpu,
                recoverable: http.statusCode >= 500
            )
        }
    }
}

struct EmptyBody: Encodable {}
