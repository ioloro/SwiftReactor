import Foundation
import OSLog

/// Module-level configuration on the ``Reactor`` class. Mirrors
/// RevenueCat's `Purchases.configure(...)` pattern: do it once at
/// app launch, then every typed `ReactorSession<Model>.connect()`
/// picks up the configured `JWTSource` automatically.
///
/// ```swift
/// // App launch — once.
/// Reactor.configure(jwt: .provider {
///     try await myBackend.mintReactorJWT()
/// })
///
/// // Anywhere — no JWT thread, no boilerplate.
/// let session = try await ReactorSession<LongLiveV2>.connect()
/// ```
///
/// Explicit per-call `jwt:` arguments to `.connect(jwt:)` still
/// work and override the configured default — useful in tests or
/// when one view wants a scoped credential.
///
/// If neither `configure(jwt:)` was called nor a per-call `jwt:`
/// was provided, `.connect()` throws
/// ``Reactor/ConfigurationError/notConfigured`` with an actionable
/// message.
public extension Reactor {

    /// Install a default ``JWTSource`` for every
    /// `ReactorSession<Model>.connect()` call that doesn't pass
    /// `jwt:` explicitly. Safe to call multiple times — the last
    /// call wins, and you can pass `nil` to clear (handy in test
    /// teardown).
    ///
    /// Most apps call this once in their `App.init()`:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///     init() {
    ///         Reactor.configure(jwt: .provider { … })
    ///     }
    ///     var body: some Scene { … }
    /// }
    /// ```
    static func configure(jwt: JWTSource?) {
        ReactorGlobalState.shared.setJWT(jwt)
    }

    /// The currently-configured ``JWTSource``, or `nil` if
    /// ``configure(jwt:)`` hasn't been called.
    static var sharedJWT: JWTSource? {
        ReactorGlobalState.shared.jwt
    }

    /// OSLog verbosity for the SDK. Defaults to ``LogLevel/info``.
    /// Flipping to ``LogLevel/debug`` at app launch is the SwiftReactor
    /// equivalent of RevenueCat's `Purchases.logLevel = .debug`.
    static var logLevel: LogLevel {
        get { ReactorGlobalState.shared.logLevel }
        set { ReactorGlobalState.shared.setLogLevel(newValue) }
    }

    /// Verbosity dial for SwiftReactor's OSLog output.
    enum LogLevel: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Errors thrown by `ReactorSession<Model>.connect()`'s no-arg
    /// overload when no JWT source is available. Named
    /// `ConfigurationError` (rather than `Error`, which would shadow
    /// the protocol when nested under a class) so doc references and
    /// call-site spellings stay unambiguous.
    enum ConfigurationError: Swift.Error, CustomStringConvertible {
        case notConfigured

        public var description: String {
            switch self {
            case .notConfigured:
                return "SwiftReactor: .connect() was called without a `jwt:` argument and Reactor.configure(jwt:) hasn't been called. Either set a default at app launch or pass `jwt:` explicitly."
            }
        }
    }

    /// Internal accessor used by `ReactorSession<Model>.connect()`
    /// overloads — returns the configured default or throws
    /// ``ConfigurationError/notConfigured``.
    static func requireConfiguredJWT() throws -> JWTSource {
        guard let jwt = ReactorGlobalState.shared.jwt else {
            throw ConfigurationError.notConfigured
        }
        return jwt
    }
}

/// Process-wide holder for ``Reactor/configure(jwt:)`` /
/// ``Reactor/logLevel`` state. Uses `os_unfair_lock` rather than an
/// `actor` because the read path is hit on every connect from
/// arbitrary isolation and an `actor` would force the call sites to
/// `await` for what's effectively a pointer read.
final class ReactorGlobalState: @unchecked Sendable {
    static let shared = ReactorGlobalState()

    private var lock = os_unfair_lock_s()
    private var _jwt: JWTSource?
    private var _logLevel: Reactor.LogLevel = .info

    var jwt: JWTSource? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _jwt
    }

    var logLevel: Reactor.LogLevel {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _logLevel
    }

    func setJWT(_ value: JWTSource?) {
        os_unfair_lock_lock(&lock)
        _jwt = value
        os_unfair_lock_unlock(&lock)
    }

    func setLogLevel(_ value: Reactor.LogLevel) {
        os_unfair_lock_lock(&lock)
        _logLevel = value
        os_unfair_lock_unlock(&lock)
    }
}
