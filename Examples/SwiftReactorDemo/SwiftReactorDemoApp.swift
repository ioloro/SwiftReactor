import SwiftUI
import SwiftReactor
import SwiftReactorDemoSupport

/// `swift run SwiftReactorDemo` from the package root launches this on
/// macOS. The app showcases one tab per Reactor model, going deep on
/// each model's specialty:
///
///   • LongLive — multi-shot grammar (setShot / sceneCut / schedule_shot)
///     with a 48-chunk per-scene budget meter.
///   • Helios — image conditioning + atomic prompt+image updates +
///     scheduled prompt changes + super-resolution toggles.
///   • LingBot — persistent action controls (WASD + look) with the
///     composite-action snapshot rendered live.
///   • SANA-Streaming — file-mode video editing with anchor-interval
///     control and re-anchor event log.
///
/// All tabs share a single `JWTSource` and connection bar. Set
/// `REACTOR_API_KEY` in the environment to mint a JWT automatically;
/// or paste a pre-minted JWT into the settings panel.
@main
struct SwiftReactorDemoApp: App {
    @StateObject private var settings = DemoSettings()

    init() {
        DemoActivationPolicy.applyRegular()
    }

    var body: some Scene {
        WindowGroup("SwiftReactor Demo") {
            ContentView()
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
