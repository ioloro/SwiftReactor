import Foundation
import Testing
@testable import SwiftReactor

@Suite("Callback registry parity with Python on(...) / off(...)")
@MainActor
struct CallbackTests {

    @Test func generic_on_off_fires_only_matching_events() async throws {
        let registry = CallbackRegistry()
        var hits = 0
        let sub = registry.register(event: .message) { _ in hits += 1 }

        registry.dispatch(.statusChanged(.ready))
        #expect(hits == 0)

        registry.dispatch(.message(AnyCodable(["k": "v"])))
        #expect(hits == 1)

        registry.unregister(sub)
        registry.dispatch(.message(AnyCodable(["k": "v"])))
        #expect(hits == 1)
    }

    @Test func multiple_handlers_on_same_event_each_fire() async throws {
        let registry = CallbackRegistry()
        var a = 0, b = 0
        _ = registry.register(event: .error) { _ in a += 1 }
        _ = registry.register(event: .error) { _ in b += 1 }
        let err = ReactorError(code: "X", message: "y", component: .api, recoverable: false)
        registry.dispatch(.error(err))
        #expect(a == 1)
        #expect(b == 1)
    }
}
