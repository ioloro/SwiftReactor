import Foundation

public extension SanaStreaming {

    /// Errors thrown by ``SanaStreamingSession`` before a command
    /// reaches the server.
    enum LocalError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Tried to `start()` while a run is already in progress.
        case alreadyStarted
        /// Tried to send a command while the underlying ``Reactor``
        /// isn't `.ready`.
        case notReady(currentStatus: ReactorStatus)
        /// Tried to use a feature that depends on `publishTrack`
        /// (sendonly tracks like a live camera feed). The WebRTC
        /// transport currently stubs `publishTrack`; track in v0.3.
        case liveModeNotYetSupported

        public var description: String {
            switch self {
            case .alreadyStarted:
                return "SanaStreaming: start() rejected — run already started (call reset() first)."
            case .notReady(let s):
                return "SanaStreaming: command rejected — Reactor status is \(s), must be .ready."
            case .liveModeNotYetSupported:
                return "SanaStreaming: live camera input requires publishTrack support, scheduled for v0.3."
            }
        }
    }
}
