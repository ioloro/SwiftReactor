import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// Regression tests for the Helios typed wrapper. Same shape as
/// `LongLiveV2SessionTests` — each test targets one failure mode the
/// typed layer is supposed to prevent.
@Suite("HeliosSession guards")
@MainActor
struct HeliosSessionTests {

    // ─────────────────────────────────────────────────────────────────
    // Wire schema
    // ─────────────────────────────────────────────────────────────────

    @Test("schedule_prompt ships `chunk` (not `at_chunk`/`session_chunk`)")
    func schedulePromptWireKey() async throws {
        let (session, mock) = try await makeReadySession()

        try await session.schedulePrompt("a coastal cliff", atChunk: 6)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "schedule_prompt" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["chunk"] as? Int == 6)
        #expect(dict["prompt"] as? String == "a coastal cliff")
        #expect(dict["at_chunk"] == nil)
        #expect(dict["session_chunk"] == nil)
    }

    @Test("set_image_strength ships `image_strength`")
    func imageStrengthWireKey() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setImageStrength(0.65)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_image_strength" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect((dict["image_strength"] as? Double) == 0.65)
    }

    @Test("set_sr_scale serialises the off/2x/4x string the server expects")
    func srScaleSerialisation() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setSRScale(.x4)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_sr_scale" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["sr_scale"] as? String == "4x")
    }

    @Test("set_conditioning bundles prompt + image atomically")
    func setConditioningBundles() async throws {
        let (session, mock) = try await makeReadySession()
        let ref = FileRef(uploadId: "u_123", name: "scene.jpg", mimeType: "image/jpeg", size: 12345)
        try await session.setConditioning(prompt: "windy plain", image: ref)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_conditioning" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["prompt"] as? String == "windy plain")
        let img = try #require(dict["image"] as? [String: Any])
        #expect(img["upload_id"] as? String == "u_123")
        #expect(img["mime_type"] as? String == "image/jpeg")
        #expect(img["size"] as? Int == 12345)
    }

    // ─────────────────────────────────────────────────────────────────
    // start is once-per-run
    // ─────────────────────────────────────────────────────────────────

    @Test("start() is rejected locally while a run is in progress")
    func doubleStartIsLocalError() async throws {
        let (session, _) = try await makeReadySession()

        try await session.setPrompt("opener")
        try await session.start()

        do {
            try await session.start()
            Issue.record("Expected start() to throw .alreadyStarted")
        } catch let err as Helios.LocalError {
            #expect(err == .alreadyStarted)
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // command_error + state snapshot
    // ─────────────────────────────────────────────────────────────────

    @Test("command_error is surfaced via lastCommandError and onCommandError")
    func commandErrorVisible() async throws {
        let (session, mock) = try await makeReadySession()

        var received: Helios.CommandErrorMessage?
        session.onCommandError { received = $0 }

        await mock.simulateLongLiveMessage(type: "command_error", data: [
            "reason": "past chunk",
            "command": "schedule_prompt",
        ])
        try await tinyWait()

        #expect(session.lastCommandError?.reason == "past chunk")
        #expect(received?.command == "schedule_prompt")
    }

    @Test("state populates the snapshot (scheduled_prompts list of objects)")
    func stateSnapshotDecoded() async throws {
        let (session, mock) = try await makeReadySession()

        await mock.simulateLongLiveMessage(type: "state", data: [
            "running": true,
            "started": true,
            "paused": false,
            "image_set": true,
            "current_chunk": 4,
            "current_frame": 132,
            "current_prompt": "fairway shot",
            "image_strength": 0.5,
            "scheduled_prompts": [
                ["prompt": "drone shot", "chunk": 8],
                ["prompt": "fly through", "chunk": 12],
            ] as [[String: Any]],
        ])
        try await tinyWait()

        let snap = try #require(session.snapshot)
        #expect(snap.currentChunk == 4)
        #expect(snap.imageSet == true)
        #expect(snap.imageStrength == 0.5)
        #expect(snap.scheduledPrompts.count == 2)
        #expect(snap.scheduledPrompts[0].prompt == "drone shot")
        #expect(snap.scheduledPrompts[0].chunk == 8)
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    private func makeReadySession() async throws -> (ReactorSession<Helios>, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "helios"),
            transportFactory: { _, _, _ in mock }
        )
        let session = ReactorSession<Helios>(reactor: reactor)
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
