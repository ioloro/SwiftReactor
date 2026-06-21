import Foundation

public struct JWTSource: Sendable {
    public typealias Resolver = @Sendable () async throws -> String

    let resolve: Resolver

    public init(_ resolver: @escaping Resolver) {
        self.resolve = resolver
    }

    public static func staticToken(_ token: String) -> JWTSource {
        JWTSource { token }
    }
}

extension JWTSource: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .staticToken(value)
    }
}
