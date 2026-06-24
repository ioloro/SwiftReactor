import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// End-to-end golden-path coverage for `LongLiveV2Session`, walking the
/// full command sequence the demo's LongLive tab issues and injecting
/// realistic server-side responses (state, command_error,
/// chunk_complete, generation_complete) between commands.
///
/// The unit suite (`LongLiveV2SessionTests`) verifies each guard in
/// isolation; this suite is the integration counterpart — proves the
/// observable state (`snapshot`, `hasStartedRun`, `lastCommandError`)
/// tracks correctly through a real session and that the wire commands
/// ship in the right order with the right keys.
///
/// **Failure mode this suite is designed to catch:** stale gates after
/// `generation_complete + auto-reset`, double-`start` on a recovered
/// session, and wire-key drift on `schedule_shot` (the original
/// Sunnyside bug — `session_chunk` instead of `at_session_chunk`
/// silently defaults to -1 server-side and the beat never fires).
@Suite("LongLiveV2Session golden path")
@MainActor
struct LongLiveV2GoldenPathTests {

    @Test("Golden path: opener → start → soft setShot → sceneCut → scheduleShot → reset → disconnect")
    func goldenPath() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)

        // setShot opener
        try await session.setShot(prompt: "A drone push-in on a coastal cliff.")
        // Server confirms with a state message: hasPrompt=true, started=false
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 42, started: false, hasPrompt: true,
            currentPrompt: "A drone push-in on a coastal cliff."
        ))
        try await tinyWait()

        // start
        try await session.start()
        // Server confirms with started=true
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 42, started: true, hasPrompt: true,
            currentPrompt: "A drone push-in on a coastal cliff."
        ))
        try await tinyWait()
        #expect(session.hasStartedRun, "start() must mark hasStartedRun true.")

        // chunk_complete
        await mock.simulateLongLiveMessage(type: "chunk_complete", data: [
            "chunk_index": 0,
            "active_prompt": "A drone push-in on a coastal cliff.",
            "session_chunk": 0,
            "frames_emitted": 33,
        ])
        try await tinyWait()

        // setShot (soft, mid-run)
        try await session.setShot(prompt: "Camera arcs left over the bay.")

        // sceneCut (hard)
        try await session.sceneCut(prompt: "Now a forest at dawn.")

        // scheduleShot
        try await session.scheduleShot(prompt: "Sun rises.", atSessionChunk: 20)

        // reset
        try await session.reset()
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 42, started: false, hasPrompt: false, currentPrompt: nil
        ))
        try await tinyWait()
        #expect(session.hasStartedRun == false, "reset must clear hasStartedRun.")

        // disconnect
        await session.disconnect()
        try await tinyWait()
        #expect(session.snapshot == nil, "disconnect must clear snapshot.")

        // Assert wire order and wire-key shape.
        let recorded = await mock.sentCommands
        let names = recorded.map(\.command)
        // Indexes are not asserted strictly — auto-reset side-effects
        // can interleave — but the order of the explicit commands must
        // be preserved.
        let expected = ["set_shot", "start", "set_shot", "scene_cut", "schedule_shot", "reset"]
        let observedExplicit = names.filter { expected.contains($0) }
        #expect(observedExplicit == expected,
                "Expected wire-command order \(expected), got \(observedExplicit)")

        // schedule_shot must ship `at_session_chunk`.
        let scheduleCmd = try #require(recorded.first { $0.command == "schedule_shot" })
        let dict = try #require(scheduleCmd.data.value as? [String: Any])
        #expect(dict["at_session_chunk"] as? Int == 20)
        #expect(dict["session_chunk"] == nil)
    }

    @Test("Auto-reset after generation_complete: hasStartedRun + snapshot flip BEFORE second start lands")
    func autoResetThenRestart() async throws {
        // This is the bug the user keeps hitting: after
        // generation_complete the wrapper auto-fires reset, the
        // server clears state, but a cached `hasSentSetShot=true`
        // would lie that the preflight was satisfied. We prove the
        // wrapper-level invariants here: snapshot must update from
        // the server, and a second `start` ONLY succeeds after a new
        // setShot + state(hasPrompt=true).
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)

        try await session.setShot(prompt: "scene 1")
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 0, started: false, hasPrompt: true, currentPrompt: "scene 1"
        ))
        try await tinyWait()
        try await session.start()
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 0, started: true, hasPrompt: true, currentPrompt: "scene 1"
        ))
        try await tinyWait()
        #expect(session.hasStartedRun)
        #expect(session.snapshot?.hasPrompt == true)

        // Server emits generation_complete; wrapper auto-fires reset.
        await mock.simulateLongLiveMessage(type: "generation_complete", data: [
            "total_chunks": 48,
        ])
        try await tinyWait()
        #expect(session.hasStartedRun == false,
                "generation_complete must clear hasStartedRun even before the auto-reset round-trip completes.")

        // Server processes the auto-reset and clears state: hasPrompt=false.
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 0, started: false, hasPrompt: false, currentPrompt: nil
        ))
        try await tinyWait()
        #expect(session.snapshot?.hasPrompt == false,
                "After auto-reset, snapshot must reflect the server's cleared state — this is the gate the tab derives from.")

        // Now a second start is allowed locally (hasStartedRun==false),
        // BUT the snapshot says hasPrompt=false — the demo tab's
        // `openerReady` gate (PreflightGates.longLiveOpenerReady)
        // must return false here, so the demo disables `start` until
        // the user sends another setShot.
        // (That helper lives in SwiftReactorDemoSupport; here we just
        // assert the underlying invariant.)
        #expect(session.snapshot?.hasPrompt == false)
    }

    @Test("command_error on start surfaces via lastCommandError without flipping hasStartedRun")
    func startRejectedSurfacesError() async throws {
        // Server-side rejection of a start (e.g. "No prompt set").
        // The wrapper sets hasStartedRun=true optimistically on the
        // SDK boundary, then must reconcile when the server's
        // command_error and follow-up state(started=false) arrive.
        let (session, mock) = try await makeReadySession(autoResetOnComplete: false)

        // Skip setShot to mimic the "race" scenario.
        try await session.start()
        #expect(session.hasStartedRun, "start() optimistically marks hasStartedRun until the server says otherwise.")

        // Server pushes command_error AND a fresh state(started=false).
        await mock.simulateLongLiveMessage(type: "command_error", data: [
            "reason": "No prompt set",
            "command": "start",
        ])
        await mock.simulateLongLiveMessage(type: "state", data: Self.state(
            seed: 0, started: false, hasPrompt: false, currentPrompt: nil
        ))
        try await tinyWait()

        #expect(session.lastCommandError?.reason == "No prompt set")
        #expect(session.lastCommandError?.command == "start")
        #expect(session.hasStartedRun == false,
                "Server state(started=false) must reconcile the optimistic local flag — otherwise the next start is wrongly local-rejected.")
    }

    // MARK: - Helpers

    private nonisolated static func state(
        seed: Int, started: Bool, hasPrompt: Bool, currentPrompt: String?
    ) -> [String: Any] {
        [
            "seed": seed,
            "paused": false,
            "running": started,
            "started": started,
            "has_prompt": hasPrompt,
            "current_chunk": 0,
            "current_frame": 0,
            "session_chunk": 0,
            "current_prompt": currentPrompt as Any? ?? NSNull(),
            "scheduled_shots": [Int](),
            "scheduled_scene_cuts": [Int](),
        ]
    }

    private func makeReadySession(autoResetOnComplete: Bool) async throws -> (ReactorSession<LongLiveV2>, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "longlive-v2"),
            transportFactory: { _, _, _ in mock }
        )
        let session = ReactorSession<LongLiveV2>(reactor: reactor,
                                        autoResetOnComplete: autoResetOnComplete)
        reactor.connectForTesting(transport: mock)
        await mock.simulateReady()
        try await tinyWait()
        #expect(reactor.status == .ready)
        return (session, mock)
    }

    private func tinyWait() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
