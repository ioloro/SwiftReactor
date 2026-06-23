import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// Regression tests for the LongLive-v2 typed wrapper. Each test
/// targets one of the failure modes the typed layer exists to
/// prevent — these are exactly the bugs we hit in Sunnyside before
/// this layer existed.
@Suite("LongLiveV2Session guards")
@MainActor
struct LongLiveV2SessionTests {

    // ─────────────────────────────────────────────────────────────────
    // Wire schema
    // ─────────────────────────────────────────────────────────────────

    @Test("schedule_shot ships `at_session_chunk`, not `session_chunk`")
    func scheduleShotWireKey() async throws {
        let (session, mock) = try await makeReadySession()

        try await session.scheduleShot(prompt: "landing", atSessionChunk: 7)

        let recorded = await mock.sentCommands
        let scheduleCmd = try #require(recorded.first { $0.command == "schedule_shot" })
        let dict = try #require(scheduleCmd.data.value as? [String: Any])
        #expect(dict["at_session_chunk"] as? Int == 7)
        #expect(dict["session_chunk"] == nil,
                "schedule_shot must not send `session_chunk` — the server defaults that to -1 and the beat never fires.")
        #expect(dict["prompt"] as? String == "landing")
    }

    @Test("schedule_scene_cut ships `at_session_chunk`")
    func scheduleSceneCutWireKey() async throws {
        let (session, mock) = try await makeReadySession()

        try await session.scheduleSceneCut(prompt: "hole 2", atSessionChunk: 12)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "schedule_scene_cut" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["at_session_chunk"] as? Int == 12)
    }

    // ─────────────────────────────────────────────────────────────────
    // start is once-per-run
    // ─────────────────────────────────────────────────────────────────

    @Test("start() is rejected locally while a run is in progress")
    func doubleStartIsLocalError() async throws {
        let (session, mock) = try await makeReadySession()

        try await session.setShot(prompt: "opener")
        try await session.start()

        await mock.resetRecording()

        do {
            try await session.start()
            Issue.record("Expected start() to throw .alreadyStarted")
        } catch let err as LongLiveV2.LocalError {
            #expect(err == .alreadyStarted)
        }

        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "start" }) == false,
                "Wire `start` must not be re-sent while hasStartedRun.")
    }

    @Test("start() unblocks after a server-side run completion")
    func startUnblocksAfterCompletion() async throws {
        // autoResetOnComplete defaults to true; disable it so we can
        // assert the unblock without an auto-reset racing the test.
        let (session, mock) = try await makeReadySession(autoResetOnComplete: false)

        try await session.setShot(prompt: "opener")
        try await session.start()
        #expect(session.hasStartedRun)

        await mock.simulateLongLiveMessage(type: "generation_complete", data: ["total_chunks": 48])
        await Task.yield()
        try await tinyWait()

        #expect(session.hasStartedRun == false)

        // A second `start` after completion must be allowed.
        await mock.resetRecording()
        try await session.start()
        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "start" }))
    }

    // ─────────────────────────────────────────────────────────────────
    // auto-reset on generation_complete
    // ─────────────────────────────────────────────────────────────────

    @Test("generation_complete auto-fires `reset` when configured")
    func autoResetOnComplete() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)
        _ = session // keep the session alive — the auto-reset `[weak self]` would otherwise see nil.

        await mock.simulateLongLiveMessage(type: "generation_complete", data: ["total_chunks": 48])
        try await tinyWait()

        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "reset" }),
                "Expected auto-reset to be sent after generation_complete.")
    }

    @Test("autoResetOnComplete=false leaves the session locked until manual reset")
    func manualResetMode() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: false)

        try await session.setShot(prompt: "opener")
        try await session.start()
        await mock.resetRecording()

        await mock.simulateLongLiveMessage(type: "generation_complete", data: ["total_chunks": 48])
        try await tinyWait()

        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "reset" }) == false,
                "With autoResetOnComplete=false, the wrapper must not auto-send reset.")
    }

    // ─────────────────────────────────────────────────────────────────
    // command_error surfacing
    // ─────────────────────────────────────────────────────────────────

    @Test("command_error is surfaced via lastCommandError and onCommandError")
    func commandErrorVisible() async throws {
        let (session, mock) = try await makeReadySession()

        var received: LongLiveV2.CommandErrorMessage?
        session.onCommandError { received = $0 }

        await mock.simulateLongLiveMessage(type: "command_error", data: [
            "reason": "prompt was empty",
            "command": "set_shot",
        ])
        try await tinyWait()

        #expect(session.lastCommandError?.reason == "prompt was empty")
        #expect(session.lastCommandError?.command == "set_shot")
        #expect(received?.reason == "prompt was empty")
    }

    // ─────────────────────────────────────────────────────────────────
    // state snapshot + disconnect clearing
    // ─────────────────────────────────────────────────────────────────

    @Test("state messages populate the snapshot (snake_case → camelCase)")
    func stateSnapshotDecoded() async throws {
        let (session, mock) = try await makeReadySession()

        await mock.simulateLongLiveMessage(type: "state", data: [
            "seed": 42,
            "paused": false,
            "running": true,
            "started": true,
            "has_prompt": true,
            "current_chunk": 5,
            "current_frame": 145,
            "session_chunk": 17,
            "current_prompt": "fairway shot",
            "scheduled_shots": [20, 30],
            "scheduled_scene_cuts": [50],
        ])
        try await tinyWait()

        let snap = try #require(session.snapshot)
        #expect(snap.currentChunk == 5)
        #expect(snap.sessionChunk == 17)
        #expect(snap.scheduledShots == [20, 30])
        #expect(snap.scheduledSceneCuts == [50])
        #expect(snap.currentPrompt == "fairway shot")
        #expect(snap.hasPrompt == true)
    }

    @Test("disconnect clears snapshot + hasStartedRun")
    func disconnectClearsSnapshot() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setShot(prompt: "opener")
        try await session.start()
        await mock.simulateLongLiveMessage(type: "state", data: [
            "seed": 0,
            "paused": false,
            "running": true,
            "started": true,
            "has_prompt": true,
            "current_chunk": 0,
            "current_frame": 0,
            "session_chunk": 0,
            "current_prompt": "opener",
            "scheduled_shots": [Int](),
            "scheduled_scene_cuts": [Int](),
        ])
        try await tinyWait()
        #expect(session.snapshot != nil)
        #expect(session.hasStartedRun)

        await session.disconnect()
        try await tinyWait()

        #expect(session.snapshot == nil)
        #expect(session.hasStartedRun == false)
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    private func makeReadySession(
        autoResetOnComplete: Bool = true
    ) async throws -> (LongLiveV2Session, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "longlive-v2"),
            transportFactory: { _, _, _ in mock }
        )
        let session = LongLiveV2Session(reactor: reactor,
                                        autoResetOnComplete: autoResetOnComplete)
        reactor.connectForTesting(transport: mock)
        await mock.simulateReady()
        try await tinyWait()
        #expect(reactor.status == .ready,
                "Expected mock-driven Reactor to be .ready, was \(reactor.status)")
        return (session, mock)
    }

    /// Yield the actor enough times that an injected async-stream message
    /// can flow: transport → Reactor.messageTask → onMessage callbacks →
    /// LongLiveV2Session.handleIncoming → any follow-up Task (e.g.
    /// auto-reset) → reactor.sendCommand → mock.sentCommands. Each hop
    /// costs at least one suspension point.
    private func tinyWait() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}
