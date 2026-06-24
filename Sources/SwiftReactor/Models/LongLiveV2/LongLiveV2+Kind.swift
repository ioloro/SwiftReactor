import Foundation

extension LongLiveV2: ReactorModelKind {
    public static var asModel: ReactorModel { .longLiveV2 }

    public static func decode(payload: AnyCodable) -> LongLiveV2.Message? {
        LongLiveV2.Message.decode(from: payload)
    }

    public static func extractState(_ message: LongLiveV2.Message) -> LongLiveV2.StateMessage? {
        if case .state(let s) = message { return s }
        return nil
    }

    public static func extractCommandError(_ message: LongLiveV2.Message) -> LongLiveV2.CommandErrorMessage? {
        if case .commandError(let e) = message { return e }
        return nil
    }

    public static func isGenerationComplete(_ message: LongLiveV2.Message) -> Bool {
        if case .generationComplete = message { return true }
        return false
    }

    public static func snapshotIndicatesStopped(_ snapshot: LongLiveV2.StateMessage) -> Bool {
        !snapshot.started
    }

    public static var alreadyStartedError: LongLiveV2.LocalError { .alreadyStarted }

    public static func notReadyError(currentStatus: ReactorStatus) -> LongLiveV2.LocalError {
        .notReady(currentStatus: currentStatus)
    }
}
