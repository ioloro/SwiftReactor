import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// End-to-end golden-path coverage for `LingBotSession`. Walks the full
/// command sequence the demo's LingBot tab issues — setPrompt +
/// setImage + start → sticky movement controls → reset → disconnect —
/// and verifies wire-key correctness for `set_movement`,
/// `set_look_horizontal`, `set_look_vertical`,
/// `set_rotation_speed_deg`.
///
/// **Upload step note:** `uploadImage` goes through the coordinator's
/// presigned-URL flow which `MockTransport` does not simulate. The
/// test injects a synthetic `FileRef` as if the upload had succeeded.
///
/// **Failure modes this catches:**
///
///   - Sticky inputs sent as the wrong wire key (e.g. `look` instead of
///     `look_horizontal`) silently default server-side.
///   - Movement enum's raw value drifting (`strafe_left` → `strafeLeft`).
///   - Auto-reset behavior on `generation_complete` (LingBot has it,
///     unlike Helios).
@Suite("LingBotSession golden path")
@MainActor
struct LingBotGoldenPathTests {

    @Test("Golden path: setPrompt + setImage + start → movement → look → reset → disconnect")
    func goldenPath() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)
        let ref = FileRef(uploadId: "u_lingbot_1", name: "world.png", mimeType: "image/png", size: 8192)

        // setPrompt
        try await session.setPrompt("Medieval village at dusk.")
        await mock.simulateLongLiveMessage(type: "prompt_accepted", data: ["prompt": "Medieval village at dusk."])
        await mock.simulateLongLiveMessage(type: "conditions_ready", data: ["has_prompt": true, "has_image": false])

        // setImage
        try await session.setImage(ref)
        await mock.simulateLongLiveMessage(type: "image_accepted", data: ["width": 1280, "height": 720])
        await mock.simulateLongLiveMessage(type: "conditions_ready", data: ["has_prompt": true, "has_image": true])
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: false, hasPrompt: true, hasImage: true,
            movement: "idle", lookHorizontal: "idle", lookVertical: "idle"
        ))
        try await tinyWait()
        #expect(session.snapshot?.hasPrompt == true)
        #expect(session.snapshot?.hasImage == true)

        // start
        try await session.start()
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: true, hasPrompt: true, hasImage: true,
            movement: "idle", lookHorizontal: "idle", lookVertical: "idle"
        ))
        try await tinyWait()
        #expect(session.hasStartedRun)

        // setMovement(.forward)
        try await session.setMovement(.forward)
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: true, hasPrompt: true, hasImage: true,
            movement: "forward", lookHorizontal: "idle", lookVertical: "idle",
            currentAction: "forward"
        ))
        try await tinyWait()
        #expect(session.snapshot?.movement == "forward")
        #expect(session.snapshot?.currentAction == "forward")

        // setLookHorizontal(.left)
        try await session.setLookHorizontal(.left)
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: true, hasPrompt: true, hasImage: true,
            movement: "forward", lookHorizontal: "left", lookVertical: "idle",
            currentAction: "forward+left"
        ))
        try await tinyWait()
        #expect(session.snapshot?.lookHorizontal == "left")
        #expect(session.snapshot?.currentAction == "forward+left")

        // setMovement(.idle) — sticky inputs explicitly turned off
        try await session.setMovement(.idle)

        // reset
        try await session.reset()
        await mock.simulateLongLiveMessage(type: "generation_reset", data: ["reason": "client requested"])
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: false, hasPrompt: false, hasImage: false,
            movement: "idle", lookHorizontal: "idle", lookVertical: "idle"
        ))
        try await tinyWait()
        #expect(session.hasStartedRun == false)

        // disconnect
        await session.disconnect()
        try await tinyWait()
        #expect(session.snapshot == nil)

        // Wire order + key shape.
        let recorded = await mock.sentCommands
        let interesting = ["set_prompt", "set_image", "start", "set_movement", "set_look_horizontal", "reset"]
        let observed = recorded.map(\.command).filter { interesting.contains($0) }
        #expect(observed == ["set_prompt", "set_image", "start", "set_movement", "set_look_horizontal", "set_movement", "reset"])

        // set_movement(.forward) → "forward"
        let movementCalls = recorded.filter { $0.command == "set_movement" }
        let firstMove = try #require(movementCalls.first?.data.value as? [String: Any])
        #expect(firstMove["movement"] as? String == "forward")

        // set_movement(.idle) → "idle"
        #expect(movementCalls.count == 2)
        let secondMove = try #require(movementCalls.last?.data.value as? [String: Any])
        #expect(secondMove["movement"] as? String == "idle")

        // set_look_horizontal must use literal `look_horizontal` key.
        let lookCmd = try #require(recorded.first { $0.command == "set_look_horizontal" })
        let lookDict = try #require(lookCmd.data.value as? [String: Any])
        #expect(lookDict["look_horizontal"] as? String == "left")
        #expect(lookDict["look"] == nil)
    }

    @Test("Auto-reset on generation_complete sends `reset` on the wire and clears hasStartedRun")
    func autoResetOnGenerationComplete() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)

        try await session.setPrompt("village")
        try await session.setImage(FileRef(uploadId: "u", name: "x.png", mimeType: "image/png", size: 1))
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: false, hasPrompt: true, hasImage: true,
            movement: "idle", lookHorizontal: "idle", lookVertical: "idle"
        ))
        try await tinyWait()
        try await session.start()
        await mock.simulateLongLiveMessage(type: "state", data: Self.lingBotStateDict(
            started: true, hasPrompt: true, hasImage: true,
            movement: "idle", lookHorizontal: "idle", lookVertical: "idle"
        ))
        try await tinyWait()
        #expect(session.hasStartedRun)

        await mock.resetRecording()
        await mock.simulateLongLiveMessage(type: "generation_complete", data: ["total_chunks": 64])
        try await tinyWait()

        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "reset" }),
                "LingBot auto-reset must send `reset` after generation_complete.")
        #expect(session.hasStartedRun == false)
    }

    @Test("setLookVertical ships `look_vertical` (regression for sister bug to look_horizontal)")
    func lookVerticalWireKey() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: false)
        try await session.setLookVertical(.up)
        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_look_vertical" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["look_vertical"] as? String == "up")
        #expect(dict["look"] == nil)
    }

    // MARK: - Helpers

    private nonisolated static func lingBotStateDict(
        started: Bool, hasPrompt: Bool, hasImage: Bool,
        movement: String, lookHorizontal: String, lookVertical: String,
        currentAction: String = "still"
    ) -> [String: Any] {
        [
            "running": started,
            "started": started,
            "paused": false,
            "current_chunk": 0,
            "current_prompt": NSNull(),
            "has_prompt": hasPrompt,
            "has_image": hasImage,
            "current_action": currentAction,
            "movement": movement,
            "look_horizontal": lookHorizontal,
            "look_vertical": lookVertical,
            "rotation_speed_deg": 5.0,
            "seed": 42,
        ]
    }

    private func makeReadySession(autoResetOnComplete: Bool) async throws -> (LingBotSession, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "lingbot"),
            transportFactory: { _, _, _ in mock }
        )
        let session = LingBotSession(reactor: reactor, autoResetOnComplete: autoResetOnComplete)
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
