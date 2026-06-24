import Foundation
import Testing
@testable import SwiftReactor
@testable import SwiftReactorDemoSupport

/// Tests for the dev-only JWT minter. Live network is mocked via a
/// `URLProtocol` stub so the test runs offline and deterministically.
@Suite("DevJWTMinter: development-only API-key → JWT helper",
       .serialized)
struct DevJWTMinterTests {

    @Test("fetchJWT returns the `jwt` field on a 200 response")
    func happyPath() async throws {
        let session = makeStubbedSession(status: 200, body: #"{"jwt": "eyJ.test.token"}"#)
        let jwt = try await DevJWTMinter.fetchJWT(
            apiKey: "rk_fake",
            mintURL: stubMintURL,
            urlSession: session
        )
        #expect(jwt == "eyJ.test.token")
    }

    @Test("fetchJWT puts the API key in the Reactor-API-Key header")
    func headerIsSet() async throws {
        StubProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Reactor-API-Key") == "rk_secret")
            #expect(request.httpMethod == "POST")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!,
                Data(#"{"jwt": "ok"}"#.utf8)
            )
        }
        _ = try await DevJWTMinter.fetchJWT(
            apiKey: "rk_secret",
            mintURL: stubMintURL,
            urlSession: makeStubbedSession()
        )
    }

    @Test("HTTP non-2xx surfaces as mintFailed with status + body")
    func httpErrorSurfaces() async {
        let session = makeStubbedSession(status: 403, body: "forbidden")
        do {
            _ = try await DevJWTMinter.fetchJWT(
                apiKey: "rk_bad",
                mintURL: stubMintURL,
                urlSession: session
            )
            Issue.record("Expected DevJWTMinterError.mintFailed")
        } catch let err as DevJWTMinterError {
            if case .mintFailed(let status, let body) = err {
                #expect(status == 403)
                #expect(body == "forbidden")
            } else {
                Issue.record("Unexpected case: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("jwtSource(apiKey:) wraps fetchJWT in a JWTSource.provider")
    func jwtSourceWraps() async throws {
        let session = makeStubbedSession(status: 200, body: #"{"jwt": "wrapped.token"}"#)
        let source = DevJWTMinter.jwtSource(
            apiKey: "rk_ok",
            mintURL: stubMintURL,
            urlSession: session
        )
        let resolved = try await source.resolve()
        #expect(resolved == "wrapped.token")
    }

    // ─────────────────────────────────────────────────────────────────
    // URLProtocol stub plumbing
    // ─────────────────────────────────────────────────────────────────

    private var stubMintURL: URL { URL(string: "https://stub.local/tokens")! }

    private func makeStubbedSession(status: Int? = nil, body: String? = nil) -> URLSession {
        if let status, let body {
            StubProtocol.handler = { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8)
                )
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}

/// `URLProtocol` that lets each test supply its own request handler.
/// Doesn't touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, body) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
