import Foundation

public extension LingBot {

    /// Errors thrown by ``LingBotSession`` before a command reaches the
    /// server.
    enum LocalError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Tried to `start()` while a run is already in progress.
        case alreadyStarted
        /// Tried to send a command while the underlying ``Reactor``
        /// isn't `.ready`.
        case notReady(currentStatus: ReactorStatus)

        public var description: String {
            switch self {
            case .alreadyStarted:
                return "LingBot: start() rejected — run already started (call reset() first)."
            case .notReady(let s):
                return "LingBot: command rejected — Reactor status is \(s), must be .ready."
            }
        }
    }
}
