import Foundation

/// Strongly-typed picker for the Reactor models SwiftReactor knows
/// about. Cases are **versioned** where Reactor itself versions the
/// model (e.g. `.longLiveV2` matches the `LongLive 2.0` brand and the
/// `longlive-v2` wire name) so an SDK update doesn't silently flip a
/// consumer onto a newer model with different semantics.
///
/// ```swift
/// let reactor = Reactor(model: .longLiveV2)
/// // For unknown / newly-launched models the SDK doesn't have a case
/// // for yet:
/// let reactor = Reactor(model: .custom("future-model-v9"))
/// ```
///
/// The case names are SwiftReactor's identifiers; ``wireName`` maps
/// them to the strings the coordinator API uses on the wire. If
/// Reactor ever renames a model on the server, the mapping is the
/// one-line patch — your call sites don't change.
public enum ReactorModel: Sendable, Hashable {
    /// `longlive-v2` — multi-shot real-time video with seamless shot
    /// changes and hard cuts. Pairs with `ReactorSession<LongLiveV2>`.
    case longLiveV2

    /// `helios` — interactive real-time streaming with image
    /// conditioning + schedulable prompt changes. Pairs with
    /// `ReactorSession<Helios>`.
    case helios

    /// `lingbot` — action-controlled world generation; persistent
    /// movement + look inputs. Pairs with `ReactorSession<LingBot>`.
    case lingbot

    /// `sana-streaming` — real-time video-to-video editing with
    /// anchor re-grounding. Pairs with `ReactorSession<SanaStreaming>`.
    case sanaStreaming

    /// Escape hatch for models SwiftReactor doesn't have a case for
    /// yet (e.g. private previews, future Reactor launches). The
    /// associated string is sent verbatim as `model.name` in the
    /// session-create request. You'll need to use the generic
    /// ``Reactor/sendCommand(_:payload:scope:)`` layer since there's
    /// no typed wrapper.
    case custom(String)

    /// Wire identifier the coordinator API expects in
    /// `client_info.model.name`.
    public var wireName: String {
        switch self {
        case .longLiveV2: return "longlive-v2"
        case .helios: return "helios"
        case .lingbot: return "lingbot"
        case .sanaStreaming: return "sana-streaming"
        case .custom(let s): return s
        }
    }
}

public extension Reactor {
    /// The primary typed-model convenience initializer. Autocomplete
    /// surfaces every supported model, typos are compile errors, and
    /// the case docs on ``ReactorModel`` show up at the call site.
    ///
    /// For advanced configuration (custom API version, on-prem base
    /// URL, etc.) construct a ``ReactorConfiguration`` directly and
    /// use ``init(configuration:urlSession:transportFactory:)``.
    convenience init(
        model: ReactorModel,
        baseURL: URL = ReactorConfiguration.productionBaseURL
    ) {
        self.init(configuration: ReactorConfiguration(model: model, baseURL: baseURL))
    }
}
