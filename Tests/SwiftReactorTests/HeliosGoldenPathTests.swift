import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// End-to-end golden-path coverage for `HeliosSession`. Walks the full
/// command sequence the demo's Helios tab issues and injects realistic
/// server responses (state, conditions_ready, chunk_complete) between
/// commands. Verifies snapshot + lastCommandError tracking and the
/// exact wire payload for `set_conditioning`, `schedule_prompt`,
/// `set_image_strength`.
///
/// **Upload step note:** `uploadImage` goes through the coordinator's
/// presigned-URL flow, which the package's `MockTransport` does not
/// simulate. The golden-path test injects a synthetic `FileRef` as if
/// the upload had succeeded, then exercises every command that
/// consumes a `FileRef`. The coordinator's two-step upload is covered
/// separately in `APIModelTests` / coordinator-level tests.
@Suite("HeliosSession golden path")
@MainActor
struct HeliosGoldenPathTests {

    @Test("Golden path: setConditioning + start → schedulePrompt → setImageStrength → reset → disconnect")
    func goldenPath() async throws {
        let (session, mock) = try await makeReadySession()
        let ref = FileRef(uploadId: "u_helios_1", name: "ref.jpg", mimeType: "image/jpeg", size: 4096)

        // setConditioning (atomic prompt + image)
        try await session.setConditioning(prompt: "A windswept plain at dusk.", image: ref)
        // Server emits image_accepted, prompt_accepted, conditions_ready, then state.
        await mock.simulateLongLiveMessage(type: "image_accepted", data: ["width": 1280, "height": 720])
        await mock.simulateLongLiveMessage(type: "prompt_accepted", data: ["prompt": "A windswept plain at dusk."])
        await mock.simulateLongLiveMessage(type: "conditions_ready", data: ["has_prompt": true, "has_image": true])
        await mock.simulateLongLiveMessage(type: "state", data: Self.heliosStateDict(
            started: false, imageSet: true, currentPrompt: "A windswept plain at dusk.", chunk: 0
        ))
        try await tinyWait()

        // start
        try await session.start()
        await mock.simulateLongLiveMessage(type: "generation_started", data: [
            "prompt": "A windswept plain at dusk.",
            "chunk_index": 0,
        ])
        await mock.simulateLongLiveMessage(type: "state", data: Self.heliosStateDict(
            started: true, imageSet: true, currentPrompt: "A windswept plain at dusk.", chunk: 0
        ))
        try await tinyWait()
        #expect(session.hasStartedRun)

        // chunk_complete a few times
        for i in 0..<3 {
            await mock.simulateLongLiveMessage(type: "chunk_complete", data: [
                "chunk_index": i,
                "frames_emitted": 33,
                "active_prompt": "A windswept plain at dusk.",
            ])
        }
        try await tinyWait()

        // schedulePrompt mid-run
        try await session.schedulePrompt("A storm rolls in, lightning flickers.", atChunk: 10)
        await mock.simulateLongLiveMessage(type: "state", data: Self.heliosStateDict(
            started: true, imageSet: true, currentPrompt: "A windswept plain at dusk.", chunk: 3,
            scheduled: [["prompt": "A storm rolls in, lightning flickers.", "chunk": 10]]
        ))
        try await tinyWait()
        #expect(session.snapshot?.scheduledPrompts.count == 1)
        #expect(session.snapshot?.scheduledPrompts.first?.chunk == 10)

        // setImageStrength (doesn't take effect until next set_image / set_conditioning)
        try await session.setImageStrength(0.7)

        // reset
        try await session.reset()
        await mock.simulateLongLiveMessage(type: "generation_reset", data: [:])
        await mock.simulateLongLiveMessage(type: "state", data: Self.heliosStateDict(
            started: false, imageSet: false, currentPrompt: nil, chunk: 0
        ))
        try await tinyWait()
        #expect(session.hasStartedRun == false)

        // disconnect
        await session.disconnect()
        try await tinyWait()
        #expect(session.snapshot == nil)

        // Assert wire order + key shape.
        let recorded = await mock.sentCommands
        let observed = recorded.map(\.command).filter {
            ["set_conditioning", "start", "schedule_prompt", "set_image_strength", "reset"].contains($0)
        }
        #expect(observed == ["set_conditioning", "start", "schedule_prompt", "set_image_strength", "reset"])

        // set_conditioning must carry prompt + nested image dict.
        let condCmd = try #require(recorded.first { $0.command == "set_conditioning" })
        let condDict = try #require(condCmd.data.value as? [String: Any])
        #expect(condDict["prompt"] as? String == "A windswept plain at dusk.")
        let img = try #require(condDict["image"] as? [String: Any])
        #expect(img["upload_id"] as? String == "u_helios_1")
        #expect(img["mime_type"] as? String == "image/jpeg")

        // schedule_prompt must use `chunk`, not `at_chunk`.
        let schedCmd = try #require(recorded.first { $0.command == "schedule_prompt" })
        let schedDict = try #require(schedCmd.data.value as? [String: Any])
        #expect(schedDict["chunk"] as? Int == 10)
        #expect(schedDict["at_chunk"] == nil)
        #expect(schedDict["session_chunk"] == nil)

        // set_image_strength must use `image_strength`, not `strength`.
        let strCmd = try #require(recorded.first { $0.command == "set_image_strength" })
        let strDict = try #require(strCmd.data.value as? [String: Any])
        #expect((strDict["image_strength"] as? Double) == 0.7)
        #expect(strDict["strength"] == nil)
    }

    @Test("schedulePrompt before start is accepted and tracked in scheduledPrompts")
    func schedulePromptBeforeStart() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.schedulePrompt("hello", atChunk: 5)
        await mock.simulateLongLiveMessage(type: "state", data: Self.heliosStateDict(
            started: false, imageSet: false, currentPrompt: nil, chunk: 0,
            scheduled: [["prompt": "hello", "chunk": 5]]
        ))
        try await tinyWait()
        #expect(session.snapshot?.scheduledPrompts.first?.prompt == "hello")
    }

    // MARK: - Helpers

    private nonisolated static func heliosStateDict(
        started: Bool, imageSet: Bool, currentPrompt: String?, chunk: Int,
        scheduled: [[String: Any]] = []
    ) -> [String: Any] {
        [
            "running": started,
            "started": started,
            "paused": false,
            "image_set": imageSet,
            "current_chunk": chunk,
            "current_frame": chunk * 33,
            "current_prompt": currentPrompt as Any? ?? NSNull(),
            "image_strength": 0.5,
            "scheduled_prompts": scheduled,
        ]
    }

    private func makeReadySession() async throws -> (HeliosSession, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "helios"),
            transportFactory: { _, _, _ in mock }
        )
        let session = HeliosSession(reactor: reactor)
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
