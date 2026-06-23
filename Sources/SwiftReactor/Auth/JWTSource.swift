import Foundation

/// Pluggable JWT resolver. ``Reactor/connect(jwt:autoResumeTracks:)``
/// calls ``resolve`` every time it needs to hit the coordinator HTTP
/// API, so a `JWTSource` is the right hook for both static tokens (dev)
/// and refresh-token flows (prod).
///
/// ```swift
/// // String literal — quick local testing.
/// try await reactor.connect(jwt: "eyJhbGciOi…")
///
/// // Pre-minted token (e.g. fetched from your backend at app launch).
/// try await reactor.connect(jwt: .staticToken(jwt))
///
/// // Backend-mint flow — runs the closure on every coordinator call.
/// try await reactor.connect(jwt: JWTSource { try await fetchJWT() })
/// ```
public struct JWTSource: Sendable {
    /// Resolver closure — re-invoked on every coordinator HTTP request,
    /// so cache aggressively at the callsite if minting is slow.
    public typealias Resolver = @Sendable () async throws -> String

    let resolve: Resolver

    /// Wrap any async closure that yields a JWT string.
    public init(_ resolver: @escaping Resolver) {
        self.resolve = resolver
    }

    /// Convenience for the common "I already have the token" case.
    /// Equivalent to `JWTSource { token }`.
    public static func staticToken(_ token: String) -> JWTSource {
        JWTSource { token }
    }
}

extension JWTSource: ExpressibleByStringLiteral {
    /// Lets you write `try await reactor.connect(jwt: "eyJ…")` — the
    /// string literal is shorthand for ``staticToken(_:)``.
    public init(stringLiteral value: String) {
        self = .staticToken(value)
    }
}
