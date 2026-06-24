import Foundation

extension Helios: ReactorModelKind {
    public static var asModel: ReactorModel { .helios }

    public static func decode(payload: AnyCodable) -> Helios.Message? {
        Helios.Message.decode(from: payload)
    }

    public static func extractState(_ message: Helios.Message) -> Helios.StateMessage? {
        if case .state(let s) = message { return s }
        return nil
    }

    public static func extractCommandError(_ message: Helios.Message) -> Helios.CommandErrorMessage? {
        if case .commandError(let e) = message { return e }
        return nil
    }

    /// Helios streams indefinitely; no `generation_complete` event
    /// in its Message enum.
    public static func isGenerationComplete(_ message: Helios.Message) -> Bool { false }

    public static func snapshotIndicatesStopped(_ snapshot: Helios.StateMessage) -> Bool {
        !snapshot.started
    }

    public static var alreadyStartedError: Helios.LocalError { .alreadyStarted }

    public static func notReadyError(currentStatus: ReactorStatus) -> Helios.LocalError {
        .notReady(currentStatus: currentStatus)
    }
}
