import Foundation

actor CoordinatorClient {
    private let configuration: ReactorConfiguration
    private let jwt: JWTSource
    private let urlSession: URLSession
    private var currentSessionId: String?

    private static let pollInitialBackoff: TimeInterval = 0.2
    private static let pollMaxBackoff: TimeInterval = 10.0
    private static let pollBackoffMultiplier: Double = 2.0
    private static let pollDefaultMaxAttempts = 20

    init(
        configuration: ReactorConfiguration,
        jwt: JWTSource,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.jwt = jwt
        self.urlSession = urlSession
    }

    var sessionId: String? { currentSessionId }

    func adopt(sessionId: String) {
        currentSessionId = sessionId
    }

    func createSession(extraArgs: [String: AnyCodable]? = nil) async throws -> CreateSessionResponse {
        let body = CreateSessionRequest(
            model: .init(name: configuration.modelName),
            clientInfo: ClientInfo(sdkVersion: configuration.sdkVersion, sdkType: "swift"),
            supportedTransports: [.init(protocol: "webrtc", version: configuration.webRTCVersion)],
            extraArgs: extraArgs
        )
        let response: CreateSessionResponse = try await post(
            path: "/sessions",
            body: body
        )
        currentSessionId = response.sessionId
        return response
    }

    func pollSessionReady(maxAttempts: Int = CoordinatorClient.pollDefaultMaxAttempts) async throws -> SessionResponse {
        guard let sessionId = currentSessionId else {
            throw ReactorError(
                code: "NO_SESSION",
                message: "Call createSession or adopt before pollSessionReady.",
                component: .api,
                recoverable: false
            )
        }
        var backoff = Self.pollInitialBackoff
        for attempt in 1...maxAttempts {
            let session: SessionResponse = try await get(path: "/sessions/\(sessionId)")
            if let state = SessionState(rawValue: session.state),
               state == .closed || state == .inactive {
                throw ReactorError(
                    code: "SESSION_TERMINAL",
                    message: "Session entered terminal state \(state.rawValue) while waiting for capabilities.",
                    component: .api,
                    recoverable: false
                )
            }
            if session.capabilities != nil && session.selectedTransport != nil {
                return session
            }
            if attempt == maxAttempts { break }
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * Self.pollBackoffMultiplier, Self.pollMaxBackoff)
        }
        throw ReactorError(
            code: "SESSION_POLL_EXHAUSTED",
            message: "Session polling exceeded maxAttempts=\(maxAttempts).",
            component: .api,
            recoverable: true
        )
    }

    func terminateSession(reason: String? = nil) async throws {
        guard let sessionId = currentSessionId else { return }
        let path = "/sessions/\(sessionId)"
        if let reason {
            try await delete(path: path, body: TerminateSessionRequest(reason: reason))
        } else {
            try await delete(path: path)
        }
        currentSessionId = nil
    }

    func createUpload(sessionId: String, request: CreateUploadRequest) async throws -> CreateUploadResponse {
        try await post(path: "/sessions/\(sessionId)/uploads", body: request)
    }

    /// Two-step upload: reserve a presigned URL with the coordinator,
    /// then PUT the bytes directly to it. Returns the presigned id the
    /// model uses to look the file up at command time.
    func uploadFile(data: Data, name: String, mimeType: String) async throws -> CreateUploadResponse {
        guard let sessionId = currentSessionId else {
            throw ReactorError(
                code: "NO_SESSION",
                message: "uploadFile requires an active session; call connect first.",
                component: .api,
                recoverable: false
            )
        }
        let presigned = try await createUpload(
            sessionId: sessionId,
            request: CreateUploadRequest(name: name, size: data.count, mimeType: mimeType)
        )
        var put = URLRequest(url: presigned.presignedURL)
        put.httpMethod = "PUT"
        put.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (body, response) = try await urlSession.upload(for: put, from: data)
        try Self.validateStatus(response, data: body)
        return presigned
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        var request = try makeRequest(path: path, method: "GET")
        try await authorize(&request)
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST", body: body)
        try await authorize(&request)
        return try await perform(request)
    }

    private func delete(path: String) async throws {
        var request = try makeRequest(path: path, method: "DELETE")
        try await authorize(&request)
        try await performVoid(request)
    }

    private func delete<Body: Encodable>(path: String, body: Body) async throws {
        var request = try makeRequest(path: path, method: "DELETE", body: body)
        try await authorize(&request)
        try await performVoid(request)
    }

    private func makeRequest(path: String, method: String, body: (any Encodable)? = nil) throws -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(String(configuration.apiVersion), forHTTPHeaderField: "Reactor-API-Version")
        request.setValue(String(configuration.apiVersion), forHTTPHeaderField: "Reactor-API-Accept-Version")
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

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await urlSession.data(for: request)
        try Self.validateStatus(response, data: data)
        return try JSONDecoder.reactor.decode(Response.self, from: data)
    }

    private func performVoid(_ request: URLRequest) async throws {
        let (data, response) = try await urlSession.data(for: request)
        try Self.validateStatus(response, data: data, allowEmpty: true)
    }

    private static func validateStatus(_ response: URLResponse, data: Data, allowEmpty: Bool = false) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ReactorError(code: "HTTP_INVALID_RESPONSE", message: "Non-HTTP response.", component: .api, recoverable: false)
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 404 where allowEmpty:
            return
        case 426:
            throw ReactorError(code: "CLIENT_VERSION_TOO_OLD", message: "Server rejected API version.", component: .api, recoverable: false)
        case 501:
            throw ReactorError(code: "SERVER_VERSION_TOO_OLD", message: "Server does not support this API version.", component: .api, recoverable: false)
        default:
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ReactorError(
                code: "HTTP_\(http.statusCode)",
                message: "HTTP \(http.statusCode) for \(http.url?.path ?? "?"): \(text)",
                component: .api,
                recoverable: http.statusCode >= 500
            )
        }
    }
}

struct AnyEncodable: Encodable {
    let wrapped: any Encodable
    init(_ wrapped: any Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}

extension JSONEncoder {
    static let reactor: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
}

extension JSONDecoder {
    static let reactor: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
