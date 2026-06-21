import Foundation

public struct ReactorError: Error, Sendable, Equatable {
    public enum Component: String, Sendable {
        case api, gpu
    }

    public let code: String
    public let message: String
    public let component: Component
    public let recoverable: Bool
    public let retryAfter: TimeInterval?
    public let timestamp: Date

    public init(
        code: String,
        message: String,
        component: Component,
        recoverable: Bool,
        retryAfter: TimeInterval? = nil,
        timestamp: Date = Date()
    ) {
        self.code = code
        self.message = message
        self.component = component
        self.recoverable = recoverable
        self.retryAfter = retryAfter
        self.timestamp = timestamp
    }
}
