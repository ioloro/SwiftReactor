import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// Tests for the RevenueCat-style `Reactor.configure(jwt:)` +
/// no-arg `.connect()` convenience. Mirrors the safety net you'd
/// hope for: configuring works, clearing works, no-arg connect
/// throws a clear error when nothing was configured.
@Suite("Reactor.configure + no-arg .connect")
@MainActor
struct SwiftReactorConfigureTests {

    @Test("configure(jwt:) populates sharedJWT")
    func configurePopulatesShared() async {
        Reactor.configure(jwt: .staticToken("eyJ.test.token"))
        defer { Reactor.configure(jwt: nil) }
        #expect(Reactor.sharedJWT != nil)
    }

    @Test("configure(jwt: nil) clears sharedJWT")
    func clearWorks() async {
        Reactor.configure(jwt: .staticToken("anything"))
        Reactor.configure(jwt: nil)
        #expect(Reactor.sharedJWT == nil)
    }

    @Test("ReactorSession<LongLiveV2>.connect() with no arg + no configure throws notConfigured")
    func noArgConnectWithoutConfigureFails() async {
        Reactor.configure(jwt: nil)
        do {
            _ = try await ReactorSession<LongLiveV2>.connect()
            Issue.record("Expected Reactor.ConfigurationError.notConfigured")
        } catch Reactor.ConfigurationError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ReactorSession<Helios>.connect() honors the same gate")
    func heliosNoArgGate() async {
        Reactor.configure(jwt: nil)
        do {
            _ = try await ReactorSession<Helios>.connect()
            Issue.record("Expected Reactor.ConfigurationError.notConfigured")
        } catch Reactor.ConfigurationError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ReactorSession<LingBot>.connect() honors the same gate")
    func lingBotNoArgGate() async {
        Reactor.configure(jwt: nil)
        do {
            _ = try await ReactorSession<LingBot>.connect()
            Issue.record("Expected Reactor.ConfigurationError.notConfigured")
        } catch Reactor.ConfigurationError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ReactorSession<SanaStreaming>.connect() honors the same gate")
    func sanaNoArgGate() async {
        Reactor.configure(jwt: nil)
        do {
            _ = try await ReactorSession<SanaStreaming>.connect()
            Issue.record("Expected Reactor.ConfigurationError.notConfigured")
        } catch Reactor.ConfigurationError.notConfigured {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("logLevel is settable and round-trips")
    func logLevelRoundTrip() async {
        let original = Reactor.logLevel
        Reactor.logLevel = .debug
        #expect(Reactor.logLevel == .debug)
        Reactor.logLevel = .warning
        #expect(Reactor.logLevel == .warning)
        Reactor.logLevel = original
    }

    @Test("LogLevel ordering is debug < info < warning < error")
    func logLevelComparable() {
        #expect(Reactor.LogLevel.debug < .info)
        #expect(Reactor.LogLevel.info < .warning)
        #expect(Reactor.LogLevel.warning < .error)
    }
}
