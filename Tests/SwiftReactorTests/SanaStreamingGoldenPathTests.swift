import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

/// End-to-end golden-path coverage for `SanaStreamingSession`. Walks
/// the full command sequence the demo's SANA tab issues — setMode(.file)
/// → setVideo → setPrompt + setAnchorInterval + start → setPrompt
/// mid-run → setAnchorInterval → reset → disconnect — and verifies
/// the anchored event flow + auto-reset behavior.
///
/// **Upload step note:** `uploadVideo` goes through the coordinator's
/// presigned-URL flow which `MockTransport` does not simulate. The
/// test injects a synthetic `FileRef` as if the upload had succeeded.
///
/// **Failure modes this catches:**
///
///   - `set_anchor_interval` wire key drift (must be `chunks`, not
///     `interval` or `anchor_interval`).
///   - `set_mode(.live)` slipping past the local guard.
///   - Auto-reset on `generation_complete` (file mode emits this when
///     the clip's last chunk ships).
@Suite("SanaStreamingSession golden path")
@MainActor
struct SanaStreamingGoldenPathTests {

    @Test("Golden path: setMode(.file) → setVideo → setPrompt + start → mid-run setPrompt → setAnchorInterval → reset → disconnect")
    func goldenPath() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)
        let ref = FileRef(uploadId: "v_sana_1", name: "clip.mp4", mimeType: "video/mp4", size: 16_384)

        // setMode(.file)
        try await session.setMode(.file)
        await mock.simulateLongLiveMessage(type: "state", data: Self.sanaStateDict(
            started: false, mode: "file", hasVideo: false, hasPrompt: false
        ))
        try await tinyWait()
        #expect(session.snapshot?.mode == "file")

        // setVideo
        try await session.setVideo(ref)
        await mock.simulateLongLiveMessage(type: "video_accepted", data: [
            "duration_seconds": 12.0,
            "frame_count": 288,
        ])
        await mock.simulateLongLiveMessage(type: "conditions_ready", data: [
            "has_prompt": false, "has_video": true,
        ])

        // setPrompt
        try await session.setPrompt("Turn it into watercolor.")
        await mock.simulateLongLiveMessage(type: "prompt_accepted", data: ["prompt": "Turn it into watercolor."])
        await mock.simulateLongLiveMessage(type: "conditions_ready", data: [
            "has_prompt": true, "has_video": true,
        ])
        await mock.simulateLongLiveMessage(type: "state", data: Self.sanaStateDict(
            started: false, mode: "file", hasVideo: true, hasPrompt: true
        ))
        try await tinyWait()

        // start
        try await session.start()
        await mock.simulateLongLiveMessage(type: "generation_started", data: [
            "prompt": "Turn it into watercolor.",
            "chunk_index": 0,
        ])
        await mock.simulateLongLiveMessage(type: "state", data: Self.sanaStateDict(
            started: true, mode: "file", hasVideo: true, hasPrompt: true
        ))
        try await tinyWait()
        #expect(session.hasStartedRun)

        // anchored events
        await mock.simulateLongLiveMessage(type: "anchored", data: ["chunk_index": 20])
        try await tinyWait()

        // setPrompt mid-run
        try await session.setPrompt("Now an oil painting.")

        // setAnchorInterval mid-run
        try await session.setAnchorInterval(chunks: 8)
        await mock.simulateLongLiveMessage(type: "state", data: Self.sanaStateDict(
            started: true, mode: "file", hasVideo: true, hasPrompt: true, anchorInterval: 8
        ))
        try await tinyWait()
        #expect(session.snapshot?.anchorInterval == 8)

        // reset (manual; auto-reset is also tested below)
        try await session.reset()
        await mock.simulateLongLiveMessage(type: "generation_reset", data: [:])
        await mock.simulateLongLiveMessage(type: "state", data: Self.sanaStateDict(
            started: false, mode: "file", hasVideo: false, hasPrompt: false
        ))
        try await tinyWait()
        #expect(session.hasStartedRun == false)

        // disconnect
        await session.disconnect()
        try await tinyWait()
        #expect(session.snapshot == nil)

        // Wire order + key shape.
        let recorded = await mock.sentCommands
        let interesting = ["set_mode", "set_video", "set_prompt", "start", "set_anchor_interval", "reset"]
        let observed = recorded.map(\.command).filter { interesting.contains($0) }
        #expect(observed == ["set_mode", "set_video", "set_prompt", "start", "set_prompt", "set_anchor_interval", "reset"])

        // set_mode payload
        let modeCmd = try #require(recorded.first { $0.command == "set_mode" })
        let modeDict = try #require(modeCmd.data.value as? [String: Any])
        #expect(modeDict["mode"] as? String == "file")

        // set_anchor_interval must ship `chunks`, not `interval`/`anchor_interval`.
        let anchorCmd = try #require(recorded.first { $0.command == "set_anchor_interval" })
        let anchorDict = try #require(anchorCmd.data.value as? [String: Any])
        #expect(anchorDict["chunks"] as? Int == 8)
        #expect(anchorDict["interval"] == nil)
        #expect(anchorDict["anchor_interval"] == nil)

        // set_video must carry `video` dict with upload_id.
        let vidCmd = try #require(recorded.first { $0.command == "set_video" })
        let vidDict = try #require(vidCmd.data.value as? [String: Any])
        let v = try #require(vidDict["video"] as? [String: Any])
        #expect(v["upload_id"] as? String == "v_sana_1")
    }

    @Test("Auto-reset on generation_complete fires reset and clears hasStartedRun")
    func autoResetOnGenerationComplete() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: true)

        try await session.setPrompt("watercolor")
        await mock.simulateLongLiveMessage(type: "state", data: Self.sanaStateDict(
            started: true, mode: "file", hasVideo: true, hasPrompt: true
        ))
        try await tinyWait()
        try await session.start()
        try await tinyWait()
        #expect(session.hasStartedRun)

        await mock.resetRecording()
        await mock.simulateLongLiveMessage(type: "generation_complete", data: ["total_chunks": 32])
        try await tinyWait()

        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "reset" }))
        #expect(session.hasStartedRun == false)
    }

    @Test("set_mode(.live) does NOT ship to the wire (publishTrack stubbed in v0.2)")
    func liveModeGuard() async throws {
        let (session, mock) = try await makeReadySession(autoResetOnComplete: false)
        do {
            try await session.setMode(.live)
            Issue.record("Expected liveModeNotYetSupported")
        } catch let err as SanaStreaming.LocalError {
            #expect(err == .liveModeNotYetSupported)
        }
        let recorded = await mock.sentCommands
        #expect(recorded.allSatisfy { $0.command != "set_mode" },
                "Live mode must never reach the wire while publishTrack is a stub.")
    }

    // MARK: - Helpers

    private nonisolated static func sanaStateDict(
        started: Bool, mode: String, hasVideo: Bool, hasPrompt: Bool,
        anchorInterval: Int = 20
    ) -> [String: Any] {
        [
            "running": started,
            "started": started,
            "paused": false,
            "mode": mode,
            "current_chunk": 0,
            "current_prompt": NSNull(),
            "has_video": hasVideo,
            "has_prompt": hasPrompt,
            "seed": NSNull(),
            "anchor_interval": anchorInterval,
        ]
    }

    private func makeReadySession(autoResetOnComplete: Bool) async throws -> (ReactorSession<SanaStreaming>, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "sana-streaming"),
            transportFactory: { _, _, _ in mock }
        )
        let session = ReactorSession<SanaStreaming>(reactor: reactor, autoResetOnComplete: autoResetOnComplete)
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
