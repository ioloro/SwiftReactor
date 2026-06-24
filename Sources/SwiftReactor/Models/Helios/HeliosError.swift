import Foundation

public extension Helios {

    /// Errors thrown by `ReactorSession<Helios>` *before* a command
    /// reaches the server. Server-originated rejections come back as
    /// ``Helios/Message/commandError`` instead.
    enum LocalError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Tried to `start()` while a run is already in progress. The
        /// state machine tracks `started` via inbound state messages
        /// and refuses to re-send `start` mid-run.
        case alreadyStarted
        /// Tried to send a command while the underlying ``Reactor``
        /// isn't `.ready`.
        case notReady(currentStatus: ReactorStatus)

        public var description: String {
            switch self {
            case .alreadyStarted:
                return "Helios: start() rejected — run already started (call reset() first)."
            case .notReady(let s):
                return "Helios: command rejected — Reactor status is \(s), must be .ready."
            }
        }
    }
}
