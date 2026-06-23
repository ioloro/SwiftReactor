import Foundation
import Testing
@testable import SwiftReactorDemoSupport

#if canImport(AppKit)
import AppKit
#endif

/// Regression suite for the silent-keystroke bug that plagued the
/// four-tab demo before `DemoActivationPolicy.applyRegular()` was
/// added to `SwiftReactorDemoApp.init`.
///
/// ### What the original bug looked like
///
/// `swift run SwiftReactorDemo` produced an executable that
/// `lsappinfo` reported as `type="BackgroundOnly"`. The window
/// appeared, the `TextField` accepted focus (AX role `AXTextField`,
/// `focused=true`), but every keystroke was eaten by macOS before
/// reaching the focused responder. A directly programmatic
/// `AXUIElementSetAttributeValue(.value, ...)` worked, which is how
/// we proved the SwiftUI binding was fine and the system was the
/// thing dropping keys.
///
/// ### How this test catches a regression
///
/// `DemoActivationPolicy.applyRegular()` is the one line standing
/// between "BackgroundOnly + dead keystrokes" and "regular app +
/// working keystrokes". The first test confirms the call flips the
/// process to `.regular`. The second guards the raw-value constant
/// the implementation relies on (NSApplication.ActivationPolicy is
/// not `RawRepresentable` over a stable contract, so we pin the
/// integer here as documentation as much as defense).
///
/// The tests run on the SwiftReactor-Package xcodebuild scheme:
///
/// ```
/// xcodebuild test \
///   -scheme SwiftReactor-Package \
///   -destination 'platform=macOS,arch=arm64'
/// ```
@Suite("Demo activation policy: silent-keystroke regression")
@MainActor
struct DemoActivationPolicyTests {

    #if canImport(AppKit)
    @Test("applyRegular flips activation policy to .regular")
    func applyRegularFlipsPolicy() {
        // Reset to a known non-regular state. `.accessory` is the
        // closest to `.prohibited` we can use without permanently
        // hiding the test runner's own dock icon (the runner is
        // itself an LSUIApp, so `.prohibited` is also fine here, but
        // `.accessory` is the cleaner choice).
        NSApplication.shared.setActivationPolicy(.accessory)
        #expect(NSApplication.shared.activationPolicy() == .accessory,
                "Pre-condition: forced .accessory so the test exercises the transition.")

        DemoActivationPolicy.applyRegular()

        #expect(NSApplication.shared.activationPolicy() == .regular,
                "applyRegular() must promote the process to .regular so key events flow to the focused responder.")
        #expect(DemoActivationPolicy.currentPolicyRawValue == DemoActivationPolicy.regularPolicyRawValue,
                "Raw-value mirror must agree with the live policy.")
    }

    @Test("applyRegular is idempotent")
    func applyRegularIsIdempotent() {
        DemoActivationPolicy.applyRegular()
        let first = NSApplication.shared.activationPolicy()
        DemoActivationPolicy.applyRegular()
        let second = NSApplication.shared.activationPolicy()

        #expect(first == .regular)
        #expect(second == .regular)
    }

    @Test("regularPolicyRawValue matches NSApplication.ActivationPolicy.regular.rawValue")
    func rawValueConstantIsCorrect() {
        // The constant exists to make the cross-platform getter
        // (`currentPolicyRawValue`) sound: it returns Int? so iOS
        // tests can skip cleanly. If Apple ever shuffles the enum
        // raw values this test fails loudly instead of silently
        // letting `currentPolicyRawValue == regularPolicyRawValue`
        // drift apart from the actual `.regular` policy.
        #expect(NSApplication.ActivationPolicy.regular.rawValue == DemoActivationPolicy.regularPolicyRawValue)
    }

    #else
    @Test("non-AppKit platforms: applyRegular is a no-op and currentPolicyRawValue is nil")
    func nonAppKitIsNoop() {
        DemoActivationPolicy.applyRegular()
        #expect(DemoActivationPolicy.currentPolicyRawValue == nil)
    }
    #endif
}
