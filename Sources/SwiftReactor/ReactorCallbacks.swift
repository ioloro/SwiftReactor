import Foundation

/// Discriminator used by ``Reactor/on(_:_:)`` to subscribe to a single
/// event family. Mirrors the string keys used by the Python and JS SDKs
/// (`"message"`, `"statusChanged"`, ...).
public enum ReactorEventName: String, Sendable, CaseIterable {
    case statusChanged
    case capabilitiesReceived
    case trackReceived
    case message
    case runtimeMessage
    case error
}

public struct ReactorSubscription: Hashable, Sendable {
    let id: UUID
    let event: ReactorEventName

    public init(id: UUID = UUID(), event: ReactorEventName) {
        self.id = id
        self.event = event
    }
}

@MainActor
final class CallbackRegistry {
    typealias Handler = (ReactorEvent) -> Void
    private var handlers: [ReactorEventName: [UUID: Handler]] = [:]

    func register(event: ReactorEventName, handler: @escaping Handler) -> ReactorSubscription {
        let sub = ReactorSubscription(event: event)
        handlers[event, default: [:]][sub.id] = handler
        return sub
    }

    func unregister(_ subscription: ReactorSubscription) {
        handlers[subscription.event]?[subscription.id] = nil
    }

    func dispatch(_ event: ReactorEvent) {
        let key = eventName(for: event)
        guard let bucket = handlers[key] else { return }
        for handler in bucket.values {
            handler(event)
        }
    }

    private func eventName(for event: ReactorEvent) -> ReactorEventName {
        switch event {
        case .statusChanged: return .statusChanged
        case .capabilitiesReceived: return .capabilitiesReceived
        case .trackReceived: return .trackReceived
        case .message: return .message
        case .runtimeMessage: return .runtimeMessage
        case .error: return .error
        }
    }
}

public extension Reactor {

    /// Generic event subscription. Mirrors Python `reactor.on("message", handler)`.
    /// Returns a ``ReactorSubscription`` token; pass it back to ``off(_:)`` to remove.
    @discardableResult
    func on(_ event: ReactorEventName, _ handler: @escaping @MainActor (ReactorEvent) -> Void) -> ReactorSubscription {
        callbackRegistry.register(event: event, handler: handler)
    }

    func off(_ subscription: ReactorSubscription) {
        callbackRegistry.unregister(subscription)
    }

    /// Fires `perform` whenever status transitions to `target`. Mirrors
    /// Python `@reactor.on_status(ReactorStatus.READY)`.
    @discardableResult
    func onStatus(_ target: ReactorStatus, perform: @escaping @MainActor () -> Void) -> ReactorSubscription {
        on(.statusChanged) { event in
            if case .statusChanged(let s) = event, s == target {
                perform()
            }
        }
    }

    @discardableResult
    func onMessage(_ handler: @escaping @MainActor (AnyCodable) -> Void) -> ReactorSubscription {
        on(.message) { event in
            if case .message(let payload) = event {
                handler(payload)
            }
        }
    }

    @discardableResult
    func onRuntimeMessage(_ handler: @escaping @MainActor (AnyCodable) -> Void) -> ReactorSubscription {
        on(.runtimeMessage) { event in
            if case .runtimeMessage(let payload) = event {
                handler(payload)
            }
        }
    }

    @discardableResult
    func onError(_ handler: @escaping @MainActor (ReactorError) -> Void) -> ReactorSubscription {
        on(.error) { event in
            if case .error(let err) = event {
                handler(err)
            }
        }
    }

    @discardableResult
    func onTrackReceived(_ handler: @escaping @MainActor (String, any TransportVideoTrack) -> Void) -> ReactorSubscription {
        on(.trackReceived) { event in
            if case .trackReceived(let name, let track) = event {
                handler(name, track)
            }
        }
    }

    @discardableResult
    func onCapabilities(_ handler: @escaping @MainActor (Capabilities) -> Void) -> ReactorSubscription {
        on(.capabilitiesReceived) { event in
            if case .capabilitiesReceived(let caps) = event {
                handler(caps)
            }
        }
    }
}
