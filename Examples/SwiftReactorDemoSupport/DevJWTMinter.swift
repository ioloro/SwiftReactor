import Foundation
import OSLog
import SwiftReactor

private let log = Logger(subsystem: "com.ioloro.SwiftReactor", category: "dev-jwt-minter")

/// Development-only helper that mints a Reactor JWT directly from an
/// `rk_…` API key by POSTing to `https://api.reactor.inc/tokens`.
///
/// **This lives in `SwiftReactorDemoSupport`, not the core SDK, on
/// purpose.** Pulling it in requires adding `SwiftReactorDemoSupport`
/// to your `Package.swift` dependencies — that extra line is the
/// friction. The core `JWTSource` only exposes `.provider` and
/// `.staticToken`, both of which are safe to ship; an unsafe path
/// shouldn't end up in production code by autocomplete.
///
/// ### When to use
///
/// - You're writing a sample app, a CLI, a CI script, an internal
///   tool, or anything else where you control deployment and your
///   API key isn't going on the App Store.
///
/// ### When NOT to use
///
/// - Shipping client app. **Anyone with the binary can extract the
///   `rk_…` key** and burn your quota. Mint JWTs in a backend you
///   control and feed them in via `JWTSource.provider { … }`.
///
/// ### Mirroring Python
///
/// The Reactor Python SDK exposes the same flow as
/// `reactor.fetch_jwt_token(api_key=…)` — a top-level utility, not a
/// core auth mode. SwiftReactor matches that pattern: it's a free
/// function in a sibling package, not a `JWTSource` factory.
public enum DevJWTMinter {

    /// Mint a JWT once. Pair with `JWTSource.provider` if you need
    /// fresh tokens on every coordinator call, but in practice a
    /// single mint at app launch covers a typical dev session.
    ///
    /// ```swift
    /// import SwiftReactor
    /// import SwiftReactorDemoSupport
    ///
    /// let jwt = try await DevJWTMinter.fetchJWT(apiKey: "rk_…")
    /// let session = try await LongLiveV2Session.connect(jwt: .staticToken(jwt))
    /// ```
    ///
    /// Logs a one-time warning to OSLog
    /// (`com.ioloro.SwiftReactor`/`dev-jwt-minter`) noting that this
    /// path is dev-only — handy for catching accidental usage in
    /// release builds that link `SwiftReactorDemoSupport` for some
    /// other reason.
    ///
    /// - Parameters:
    ///   - apiKey: An `rk_…` Reactor API key.
    ///   - mintURL: Override for staging / on-prem coordinators.
    ///     Defaults to `https://api.reactor.inc/tokens`.
    ///   - urlSession: Override for tests / dependency injection.
    public static func fetchJWT(
        apiKey: String,
        mintURL: URL = DevJWTMinter.defaultMintURL,
        urlSession: URLSession = .shared
    ) async throws -> String {
        OneShotWarner.shared.warnOnce()
        var req = URLRequest(url: mintURL)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "Reactor-API-Key")
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DevJWTMinterError.mintFailed(status: status, body: body)
        }
        struct Response: Decodable { let jwt: String }
        return try JSONDecoder().decode(Response.self, from: data).jwt
    }

    /// Convenience that wraps ``fetchJWT(apiKey:mintURL:urlSession:)``
    /// in a `JWTSource.provider { … }`. Each coordinator HTTP call
    /// hits `/tokens` again, so tokens stay fresh — at the cost of an
    /// extra round trip per call.
    ///
    /// For most dev sessions a single mint via `fetchJWT` + a
    /// `.staticToken` is enough; reach for this if you're hitting JWT
    /// expiry mid-session.
    public static func jwtSource(
        apiKey: String,
        mintURL: URL = DevJWTMinter.defaultMintURL,
        urlSession: URLSession = .shared
    ) -> JWTSource {
        .provider {
            try await DevJWTMinter.fetchJWT(
                apiKey: apiKey, mintURL: mintURL, urlSession: urlSession
            )
        }
    }

    /// `https://api.reactor.inc/tokens` — Reactor's JWT mint endpoint.
    public static let defaultMintURL: URL = {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "api.reactor.inc"
        c.path = "/tokens"
        guard let url = c.url else {
            fatalError("DevJWTMinter: defaultMintURL constants are malformed.")
        }
        return url
    }()
}

public enum DevJWTMinterError: Error, Equatable, CustomStringConvertible {
    case mintFailed(status: Int, body: String)

    public var description: String {
        switch self {
        case .mintFailed(let status, let body):
            return "DevJWTMinter: Reactor /tokens responded HTTP \(status): \(body)"
        }
    }
}

/// Process-wide one-shot warning. Class instead of an actor so the
/// `fetchJWT` static can call it from any isolation context without
/// `await`; locked with `os_unfair_lock` because the flip is trivial.
private final class OneShotWarner: @unchecked Sendable {
    static let shared = OneShotWarner()

    private var lock = os_unfair_lock_s()
    private var fired = false

    func warnOnce() {
        os_unfair_lock_lock(&lock)
        let shouldFire = !fired
        fired = true
        os_unfair_lock_unlock(&lock)
        guard shouldFire else { return }
        log.warning(
            "DevJWTMinter is in use. This is for development only — your rk_… API key is reachable to anyone with the client binary. In production, mint JWTs in a backend you control and use JWTSource.provider { … } instead."
        )
    }
}
