import Foundation

/// How the SDK obtains a JWT to authenticate every coordinator HTTP
/// call. SwiftReactor re-resolves this on each request, so a single
/// `JWTSource` covers the whole connection lifecycle.
///
/// Two safe flavors:
///
/// 1. **``provider(_:)``** — the recommended path. Give the SDK a
///    closure that calls *your* backend, and your backend mints the
///    JWT using its server-held Reactor API key. The API key never
///    sees the client binary.
///
/// 2. **``staticToken(_:)``** — also safe; the JWT you pass in was
///    minted somewhere safer (your backend at app launch, an MDM
///    profile, etc.) and is treated as opaque by the SDK.
///
/// ```swift
/// // Recommended:
/// let session = try await ReactorSession<LongLiveV2>.connect(jwt: .provider {
///     try await myBackend.mintReactorJWT()
/// })
///
/// // Pre-minted (also fine):
/// let session = try await ReactorSession<LongLiveV2>.connect(jwt: .staticToken(jwt))
/// ```
///
/// For local development you may want to mint JWTs directly from a
/// Reactor API key. That path is intentionally not in the core SDK
/// — adding `SwiftReactorDemoSupport` as a dependency gives you
/// `DevJWTMinter.fetchJWT(apiKey:)`, which carries an extra package-
/// level friction step so the unsafe path doesn't accidentally end
/// up in production binaries.
public struct JWTSource: Sendable {
    /// Resolver closure — invoked on every coordinator HTTP request,
    /// so cache aggressively at the call site if minting is slow.
    public typealias Resolver = @Sendable () async throws -> String

    let resolve: Resolver

    /// Internal initializer. The public surface is intentionally
    /// limited to the named factories (``provider(_:)``,
    /// ``staticToken(_:)``) so call sites read as intent rather than
    /// a closure literal.
    init(_ resolver: @escaping Resolver) {
        self.resolve = resolver
    }

    /// Hand the SDK a closure that fetches a fresh JWT — typically
    /// against *your* backend, which holds the Reactor API key.
    /// **Recommended default.**
    ///
    /// The closure is re-invoked on every coordinator HTTP call, so
    /// short-lived tokens work without rewiring: keep your backend
    /// minting cheap and the SDK will pick up rotation transparently.
    public static func provider(_ resolver: @escaping Resolver) -> JWTSource {
        JWTSource(resolver)
    }

    /// Convenience for the "I already have the token" case. The SDK
    /// treats the string as opaque; whatever minted it (your
    /// backend, an MDM profile, a CLI-pasted value) is your business.
    public static func staticToken(_ token: String) -> JWTSource {
        JWTSource { token }
    }
}

extension JWTSource: ExpressibleByStringLiteral {
    /// Lets you write `connect(jwt: "eyJ…")` — string literal is
    /// shorthand for ``staticToken(_:)``.
    public init(stringLiteral value: String) {
        self = .staticToken(value)
    }
}
