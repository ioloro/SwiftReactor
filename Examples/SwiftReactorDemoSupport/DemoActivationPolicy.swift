import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Promotes the SwiftPM-launched demo from `LSBackgroundOnly` (the
/// default for a SwiftPM `executableTarget` without an `Info.plist`)
/// to a regular foreground app.
///
/// ### Why this exists
///
/// `swift run SwiftReactorDemo` produces a plain command-line
/// executable. `lsappinfo` reports it as `type="BackgroundOnly"`.
/// macOS will not route keyboard events to a background-only app
/// even when it draws a window. The symptom is a `TextField` that
/// **appears focused** (cursor blinks, AX role `AXTextField`,
/// `focused=true`) **but silently swallows every keystroke**.
///
/// Calling `NSApplication.shared.setActivationPolicy(.regular)`
/// before the first `NSApp.run()` flips the app to a normal LSUI
/// app, restores key-event delivery to the focused responder, and
/// makes the four tab `TextField`s editable. `activate(ignoringOtherApps: true)`
/// then pulls the window to the foreground so the user doesn't have
/// to click in the Dock first.
///
/// ### Why not an `Info.plist`?
///
/// A SwiftPM `executableTarget` doesn't carry an `Info.plist` by
/// default, and adding one to a non-`.app`-bundle SwiftPM target is
/// awkward (the resource is loaded at runtime, but `Lsappinfo` reads
/// the bundle's plist at registration time, which is too late). The
/// `setActivationPolicy(.regular)` call works at any time before
/// `NSApp.run()`.
///
/// ### Why isolate it
///
/// This is the kind of bug that's nearly impossible to find without
/// AX-level inspection. Pulling the policy switch into its own named
/// type means future engineers can grep for `DemoActivationPolicy`
/// and find this comment, and the regression test (
/// `DemoActivationPolicyTests`) can assert the policy applies
/// without launching a window.
public enum DemoActivationPolicy {

    /// Promote to a regular (foreground) app and bring its windows
    /// to the front. Safe to call multiple times: `NSApplication`
    /// no-ops a redundant policy assignment, and `activate(...)` on
    /// an already-active app is also a no-op.
    ///
    /// `NSApplication.shared` is `@MainActor`-isolated, so this
    /// method is too. Call it from `App.init` (which SwiftUI invokes
    /// on the main actor) or from any other `@MainActor` context.
    @MainActor
    public static func applyRegular() {
        #if canImport(AppKit)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Without this, the window comes up behind whatever app was
        // frontmost when `swift run` was invoked. The policy switch
        // alone fixes the keystroke bug, but the activate call fixes
        // the "where did my window go?" follow-on.
        app.activate(ignoringOtherApps: true)
        #endif
    }

    /// Test-only inspection of the current activation policy. Returns
    /// `nil` on platforms where `NSApplication` isn't available, so
    /// the regression test can be skipped cleanly on iOS.
    @MainActor
    public static var currentPolicyRawValue: Int? {
        #if canImport(AppKit)
        return NSApplication.shared.activationPolicy().rawValue
        #else
        return nil
        #endif
    }

    /// `.regular` is rawValue `0` on every macOS version since the
    /// API was introduced. Exposed as a constant so the test asserts
    /// against this rather than re-reading the enum (the policy
    /// getter doesn't require Mojave-only API but the enum case
    /// access does, so we compare integer raw values).
    public static let regularPolicyRawValue: Int = 0
}
