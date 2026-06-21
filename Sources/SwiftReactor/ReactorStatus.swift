import Foundation

public enum ReactorStatus: String, Sendable, Equatable {
    case disconnected
    case connecting
    case waiting
    case ready
}

public enum TransportStatus: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case error
}
