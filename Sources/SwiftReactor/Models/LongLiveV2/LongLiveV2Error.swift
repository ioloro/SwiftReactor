import Foundation

public extension LongLiveV2 {

    /// Errors thrown by `LongLiveV2Session` *before* a command would be
    /// sent to the server — caught locally by the state machine. Server-
    /// originated rejections come back as `LongLiveV2.Message.commandError`
    /// instead.
    enum LocalError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Tried to `start()` while a run is already in progress. The
        /// state machine tracks `started` from incoming state messages
        /// and refuses to re-send `start` mid-run.
        case alreadyStarted
        /// Tried to send a command while the underlying `Reactor` isn't
        /// `.ready` — the typed methods front-load this check so the
        /// stack trace points at the offending call site.
        case notReady(currentStatus: ReactorStatus)

        public var description: String {
            switch self {
            case .alreadyStarted:
                return "LongLiveV2: start() rejected — run already started (call reset() first)."
            case .notReady(let s):
                return "LongLiveV2: command rejected — Reactor status is \(s), must be .ready."
            }
        }
    }
}
