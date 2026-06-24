import Foundation
import SwiftReactor
import SwiftReactorDemoSupport

/// Shared app settings — credentials + a single JWT source that all
/// tabs read. Stored in `UserDefaults` so a paste-once-run-many flow
/// works across launches.
@MainActor
final class DemoSettings: ObservableObject {
    @Published var apiKey: String
    @Published var staticJWT: String

    init() {
        let defaults = UserDefaults.standard
        self.apiKey = defaults.string(forKey: "demo.reactor.apiKey")
            ?? ProcessInfo.processInfo.environment["REACTOR_API_KEY"]
            ?? ""
        self.staticJWT = defaults.string(forKey: "demo.reactor.jwt") ?? ""
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: "demo.reactor.apiKey")
        defaults.set(staticJWT, forKey: "demo.reactor.jwt")
    }

    /// Build a `JWTSource` — pre-minted token wins over the API-key
    /// path. `DevJWTMinter.jwtSource(apiKey:)` lives in the
    /// `SwiftReactorDemoSupport` target on purpose: it's a development
    /// helper, not part of the SDK's safe public surface. Production
    /// apps should mint JWTs in a backend and use
    /// `JWTSource.provider { … }` instead.
    func makeJWTSource() throws -> JWTSource {
        if !staticJWT.isEmpty {
            return .staticToken(staticJWT)
        }
        guard !apiKey.isEmpty else {
            throw DemoError.missingCredentials
        }
        return DevJWTMinter.jwtSource(apiKey: apiKey)
    }
}

enum DemoError: LocalizedError {
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No JWT and no REACTOR_API_KEY — paste either one in Settings."
        }
    }
}
