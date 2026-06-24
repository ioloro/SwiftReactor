import Foundation

extension LingBot: ReactorModelKind {
    public static var asModel: ReactorModel { .lingbot }

    public static func decode(payload: AnyCodable) -> LingBot.Message? {
        LingBot.Message.decode(from: payload)
    }

    public static func extractState(_ message: LingBot.Message) -> LingBot.StateMessage? {
        if case .state(let s) = message { return s }
        return nil
    }

    public static func extractCommandError(_ message: LingBot.Message) -> LingBot.CommandErrorMessage? {
        if case .commandError(let e) = message { return e }
        return nil
    }

    public static func isGenerationComplete(_ message: LingBot.Message) -> Bool {
        if case .generationComplete = message { return true }
        return false
    }

    public static func snapshotIndicatesStopped(_ snapshot: LingBot.StateMessage) -> Bool {
        !snapshot.started
    }

    public static var alreadyStartedError: LingBot.LocalError { .alreadyStarted }

    public static func notReadyError(currentStatus: ReactorStatus) -> LingBot.LocalError {
        .notReady(currentStatus: currentStatus)
    }
}
