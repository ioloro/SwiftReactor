import Foundation

extension SanaStreaming: ReactorModelKind {
    public static var asModel: ReactorModel { .sanaStreaming }

    public static func decode(payload: AnyCodable) -> SanaStreaming.Message? {
        SanaStreaming.Message.decode(from: payload)
    }

    public static func extractState(_ message: SanaStreaming.Message) -> SanaStreaming.StateMessage? {
        if case .state(let s) = message { return s }
        return nil
    }

    public static func extractCommandError(_ message: SanaStreaming.Message) -> SanaStreaming.CommandErrorMessage? {
        if case .commandError(let e) = message { return e }
        return nil
    }

    public static func isGenerationComplete(_ message: SanaStreaming.Message) -> Bool {
        if case .generationComplete = message { return true }
        return false
    }

    public static func snapshotIndicatesStopped(_ snapshot: SanaStreaming.StateMessage) -> Bool {
        !snapshot.started
    }

    public static var alreadyStartedError: SanaStreaming.LocalError { .alreadyStarted }

    public static func notReadyError(currentStatus: ReactorStatus) -> SanaStreaming.LocalError {
        .notReady(currentStatus: currentStatus)
    }
}
