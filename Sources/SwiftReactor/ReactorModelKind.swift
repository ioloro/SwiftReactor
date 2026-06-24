import Foundation

/// Compile-time identity for a Reactor model. Each model namespace
/// (`LongLiveV2`, `Helios`, `LingBot`, `SanaStreaming`) conforms so
/// that ``ReactorSession`` can be parameterised by model type and
/// still know how to decode messages, extract snapshots, etc.
///
/// You don't conform your own types to this — the four built-in
/// conformers cover every typed model SwiftReactor supports. For
/// models without a typed wrapper (private previews, future
/// launches) use the generic ``Reactor`` directly.
public protocol ReactorModelKind {
    /// The model's observable state snapshot type — the decoded
    /// payload of every `state` message the server emits.
    associatedtype StateMessage: Decodable, Sendable, Equatable

    /// The model's command-rejection message type — the decoded
    /// payload of every `command_error` the server emits.
    associatedtype CommandErrorMessage: Decodable, Sendable, Equatable

    /// The model's typed Message enum (every event the server can
    /// send, decoded into a single sum type).
    associatedtype Message: Sendable

    /// Errors thrown locally by ``ReactorSession`` before a command
    /// reaches the server (e.g. double-start, wrong status).
    associatedtype LocalError: Error, Sendable

    /// The matching ``ReactorModel`` case. Used by
    /// ``ReactorSession``'s `.connect(...)` factory to build a
    /// `Reactor(model:)` of the right wire identity.
    static var asModel: ReactorModel { get }

    /// Decode a raw wire payload into the typed Message enum. The
    /// payload is the inner application envelope `{type, data:{…}}`
    /// the transport delivers to `Reactor.onMessage`.
    static func decode(payload: AnyCodable) -> Message?

    /// Extract the snapshot from a `Message` if it's a `.state(...)`
    /// case. Returns nil for any other message.
    static func extractState(_ message: Message) -> StateMessage?

    /// Extract the command-error payload from a `Message` if it's a
    /// `.commandError(...)` case. Returns nil for any other message.
    static func extractCommandError(_ message: Message) -> CommandErrorMessage?

    /// True if the message signals end-of-run (e.g.
    /// `.generationComplete`). Used by ``ReactorSession`` to decide
    /// whether to auto-fire `reset`. Models without a natural end of
    /// run (e.g. Helios, which streams indefinitely) return `false`
    /// for every message.
    static func isGenerationComplete(_ message: Message) -> Bool

    /// True if the message signals the server has flipped `started`
    /// to `false` (without an explicit generation_complete) — for
    /// models that publish that via the snapshot rather than a
    /// dedicated event. ``ReactorSession`` uses this to clear its
    /// optimistic `hasStartedRun` flag.
    static func snapshotIndicatesStopped(_ snapshot: StateMessage) -> Bool

    /// `LocalError.alreadyStarted` constructor for the model. Used
    /// by the shared `start()` guard.
    static var alreadyStartedError: LocalError { get }

    /// `LocalError.notReady(currentStatus:)` constructor. Used by
    /// the shared status precondition checks.
    static func notReadyError(currentStatus: ReactorStatus) -> LocalError
}
