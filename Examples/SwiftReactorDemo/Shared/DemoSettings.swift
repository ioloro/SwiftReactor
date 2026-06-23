import Foundation
import SwiftReactor

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

    /// Build a `JWTSource` that either returns the pasted JWT or mints
    /// one from the API key. The mint endpoint is the standard Reactor
    /// coordinator token endpoint.
    func makeJWTSource() -> JWTSource {
        let token = staticJWT
        let key = apiKey
        if !token.isEmpty {
            return .staticToken(token)
        }
        return JWTSource {
            try await Self.mintJWT(apiKey: key)
        }
    }

    private static func mintJWT(apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw DemoError.missingCredentials
        }
        var req = URLRequest(url: URL(string: "https://api.reactor.inc/tokens")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "Reactor-API-Key")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DemoError.mintFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body)")
        }
        struct R: Decodable { let jwt: String }
        return try JSONDecoder().decode(R.self, from: data).jwt
    }
}

enum DemoError: LocalizedError {
    case missingCredentials
    case mintFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No JWT and no REACTOR_API_KEY — paste either one in Settings."
        case .mintFailed(let detail):
            return "JWT mint failed: \(detail)"
        }
    }
}
