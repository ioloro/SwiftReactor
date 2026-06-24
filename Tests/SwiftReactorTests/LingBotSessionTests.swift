import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

@Suite("LingBotSession guards")
@MainActor
struct LingBotSessionTests {

    // ─────────────────────────────────────────────────────────────────
    // Wire schema: enum serialisation
    // ─────────────────────────────────────────────────────────────────

    @Test("set_movement serialises the enum to the literal wire string")
    func movementSerialisation() async throws {
        let (session, mock) = try await makeReadySession()

        try await session.setMovement(.strafeLeft)
        try await session.setMovement(.forward)

        let recorded = await mock.sentCommands
        let strafe = try #require(recorded.first { $0.command == "set_movement" })
        let strafeDict = try #require(strafe.data.value as? [String: Any])
        // First call was strafeLeft → wire string "strafe_left"
        #expect(strafeDict["movement"] as? String == "strafe_left")

        let calls = recorded.filter { $0.command == "set_movement" }
        #expect(calls.count == 2)
        let secondDict = try #require(calls[1].data.value as? [String: Any])
        #expect(secondDict["movement"] as? String == "forward")
    }

    @Test("set_look_horizontal ships `look_horizontal` (not `look`)")
    func lookHorizontalWireKey() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setLookHorizontal(.right)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_look_horizontal" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["look_horizontal"] as? String == "right")
        #expect(dict["look"] == nil)
    }

    @Test("set_rotation_speed_deg ships `rotation_speed_deg` (not `rotation_speed`)")
    func rotationSpeedWireKey() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setRotationSpeed(degreesPerChunk: 12.5)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_rotation_speed_deg" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect((dict["rotation_speed_deg"] as? Double) == 12.5)
        #expect(dict["rotation_speed"] == nil)
    }

    @Test("set_image embeds the FileRef as the documented dict shape")
    func setImageWirePayload() async throws {
        let (session, mock) = try await makeReadySession()
        let ref = FileRef(uploadId: "ul_xyz", name: "world.png", mimeType: "image/png", size: 42)
        try await session.setImage(ref)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_image" })
        let dict = try #require(cmd.data.value as? [String: Any])
        let img = try #require(dict["image"] as? [String: Any])
        #expect(img["upload_id"] as? String == "ul_xyz")
        #expect(img["name"] as? String == "world.png")
        #expect(img["mime_type"] as? String == "image/png")
        #expect(img["size"] as? Int == 42)
    }

    // ─────────────────────────────────────────────────────────────────
    // start once-per-run
    // ─────────────────────────────────────────────────────────────────

    @Test("start() is rejected locally while a run is in progress")
    func doubleStartIsLocalError() async throws {
        let (session, _) = try await makeReadySession()
        try await session.setPrompt("opener")
        try await session.start()

        do {
            try await session.start()
            Issue.record("Expected .alreadyStarted")
        } catch let err as LingBot.LocalError {
            #expect(err == .alreadyStarted)
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // state snapshot decoding
    // ─────────────────────────────────────────────────────────────────

    @Test("state populates the composite action snapshot")
    func compositeActionDecoded() async throws {
        let (session, mock) = try await makeReadySession()

        await mock.simulateLongLiveMessage(type: "state", data: [
            "running": true,
            "started": true,
            "paused": false,
            "current_chunk": 7,
            "current_prompt": "stone arch",
            "has_prompt": true,
            "has_image": true,
            "current_action": "forward+left",
            "movement": "forward",
            "look_horizontal": "left",
            "look_vertical": "idle",
            "rotation_speed_deg": 5.0,
            "seed": 42,
        ])
        try await tinyWait()

        let snap = try #require(session.snapshot)
        #expect(snap.currentAction == "forward+left")
        #expect(snap.movement == "forward")
        #expect(snap.lookHorizontal == "left")
        #expect(snap.hasImage)
        #expect(snap.rotationSpeedDeg == 5.0)
    }

    @Test("generation_reset surfaces with the server's reason string")
    func resetMessageDecoded() async throws {
        let (session, mock) = try await makeReadySession()

        var received: LingBot.GenerationResetMessage?
        session.onMessage { msg in
            if case .generationReset(let r) = msg { received = r }
        }

        await mock.simulateLongLiveMessage(type: "generation_reset", data: [
            "reason": "client requested",
        ])
        try await tinyWait()

        #expect(received?.reason == "client requested")
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    private func makeReadySession() async throws -> (ReactorSession<LingBot>, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "lingbot"),
            transportFactory: { _, _, _ in mock }
        )
        let session = ReactorSession<LingBot>(reactor: reactor)
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
