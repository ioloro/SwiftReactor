import Foundation

/// Connection-level settings for ``Reactor``. Most consumers use the
/// `Reactor(modelName:)` convenience and never construct this directly;
/// reach for it when you need to point at a non-production coordinator
/// (staging, on-prem, the local runtime) or bump the API version.
public struct ReactorConfiguration: Sendable {
    /// Coordinator HTTP base URL. Defaults to ``productionBaseURL`` —
    /// override for staging or `http://localhost:8080` when running the
    /// `reactor local` runtime.
    public var baseURL: URL
    /// Model identifier you want to connect to. The coordinator uses
    /// this to route the session to the right GPU pool. Examples:
    /// `"longlive-v2"`, `"helios"`, `"lingbot"`, `"sana-streaming"`.
    public var modelName: String
    /// Reactor coordinator API version. Bumped via the
    /// `Reactor-API-Version` / `Reactor-API-Accept-Version` headers.
    /// Servers that don't speak this version respond with HTTP 426 /
    /// 501, surfaced as ``ReactorError`` codes
    /// `CLIENT_VERSION_TOO_OLD` / `SERVER_VERSION_TOO_OLD`.
    public var apiVersion: Int
    /// WebRTC subprotocol version declared in the `supported_transports`
    /// section of the session-create request.
    public var webRTCVersion: String
    /// SDK self-identifier sent in `client_info.sdk_version` so server
    /// telemetry can distinguish Swift consumers from the JS / Python
    /// SDKs. Bumped on each SwiftReactor release.
    public var sdkVersion: String

    public init(
        modelName: String,
        baseURL: URL = ReactorConfiguration.productionBaseURL,
        apiVersion: Int = 1,
        webRTCVersion: String = "1.0",
        sdkVersion: String = ReactorConfiguration.currentSDKVersion
    ) {
        self.modelName = modelName
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.webRTCVersion = webRTCVersion
        self.sdkVersion = sdkVersion
    }

    /// Production coordinator at `https://api.reactor.inc`.
    public static let productionBaseURL: URL = {
        // Use components rather than force-unwrap so the SDK fails loudly
        // and immediately if the literal ever becomes malformed (caught
        // by the unit-test pass that imports SwiftReactor).
        var c = URLComponents()
        c.scheme = "https"
        c.host = "api.reactor.inc"
        guard let url = c.url else {
            fatalError("SwiftReactor: productionBaseURL constants are malformed.")
        }
        return url
    }()

    /// Local runtime base URL: `http://localhost:8080`. Hand this to
    /// ``init(modelName:baseURL:apiVersion:webRTCVersion:sdkVersion:)``
    /// when you're running `reactor local` against an on-box GPU.
    public static let localBaseURL: URL = {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "localhost"
        c.port = 8080
        guard let url = c.url else {
            fatalError("SwiftReactor: localBaseURL constants are malformed.")
        }
        return url
    }()

    /// Current SwiftReactor release. Sent to the coordinator as
    /// `client_info.sdk_version`.
    public static let currentSDKVersion = "0.2.0"
}
