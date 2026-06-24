import Foundation
import Testing
@_spi(Testing) @testable import SwiftReactor

@Suite("SanaStreamingSession guards")
@MainActor
struct SanaStreamingSessionTests {

    // ─────────────────────────────────────────────────────────────────
    // Wire schema
    // ─────────────────────────────────────────────────────────────────

    @Test("set_anchor_interval ships `chunks` (not `interval`/`anchor_interval`)")
    func anchorIntervalWireKey() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setAnchorInterval(chunks: 8)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_anchor_interval" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["chunks"] as? Int == 8)
        #expect(dict["interval"] == nil)
        #expect(dict["anchor_interval"] == nil)
    }

    @Test("set_video embeds the FileRef as the documented dict shape")
    func setVideoWirePayload() async throws {
        let (session, mock) = try await makeReadySession()
        let ref = FileRef(uploadId: "v_777", name: "clip.mp4", mimeType: "video/mp4", size: 9001)
        try await session.setVideo(ref)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_video" })
        let dict = try #require(cmd.data.value as? [String: Any])
        let video = try #require(dict["video"] as? [String: Any])
        #expect(video["upload_id"] as? String == "v_777")
        #expect(video["mime_type"] as? String == "video/mp4")
    }

    @Test("set_mode(.file) is sent on the wire")
    func fileModeAccepted() async throws {
        let (session, mock) = try await makeReadySession()
        try await session.setMode(.file)

        let recorded = await mock.sentCommands
        let cmd = try #require(recorded.first { $0.command == "set_mode" })
        let dict = try #require(cmd.data.value as? [String: Any])
        #expect(dict["mode"] as? String == "file")
    }

    // ─────────────────────────────────────────────────────────────────
    // Live mode guard (v0.2 SDK doesn't ship publishTrack)
    // ─────────────────────────────────────────────────────────────────

    @Test("set_mode(.live) throws liveModeNotYetSupported locally")
    func liveModeRejectedLocally() async throws {
        let (session, mock) = try await makeReadySession()

        do {
            try await session.setMode(.live)
            Issue.record("Expected liveModeNotYetSupported")
        } catch let err as SanaStreaming.LocalError {
            #expect(err == .liveModeNotYetSupported)
        }

        let recorded = await mock.sentCommands
        #expect(recorded.contains(where: { $0.command == "set_mode" }) == false,
                "set_mode(.live) must not ship to the wire while publishTrack is stubbed.")
    }

    // ─────────────────────────────────────────────────────────────────
    // start once-per-run
    // ─────────────────────────────────────────────────────────────────

    @Test("start() is rejected locally while a run is in progress")
    func doubleStartIsLocalError() async throws {
        let (session, _) = try await makeReadySession()
        try await session.setPrompt("turn it into watercolor")
        try await session.start()

        do {
            try await session.start()
            Issue.record("Expected .alreadyStarted")
        } catch let err as SanaStreaming.LocalError {
            #expect(err == .alreadyStarted)
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // anchored event + state snapshot
    // ─────────────────────────────────────────────────────────────────

    @Test("anchored event is surfaced via onAnchored")
    func anchoredEventRouted() async throws {
        let (session, mock) = try await makeReadySession()

        var lastChunk: Int?
        session.onAnchored { lastChunk = $0.chunkIndex }

        await mock.simulateLongLiveMessage(type: "anchored", data: ["chunk_index": 20])
        try await tinyWait()

        #expect(lastChunk == 20)
    }

    @Test("state populates the snapshot")
    func stateSnapshotDecoded() async throws {
        let (session, mock) = try await makeReadySession()

        await mock.simulateLongLiveMessage(type: "state", data: [
            "running": true,
            "started": true,
            "paused": false,
            "mode": "file",
            "current_chunk": 14,
            "current_prompt": "ghibli style",
            "has_video": true,
            "has_prompt": true,
            "seed": NSNull(),
            "anchor_interval": 20,
        ])
        try await tinyWait()

        let snap = try #require(session.snapshot)
        #expect(snap.mode == "file")
        #expect(snap.currentChunk == 14)
        #expect(snap.hasVideo)
        #expect(snap.anchorInterval == 20)
        #expect(snap.seed == nil)
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    private func makeReadySession() async throws -> (ReactorSession<SanaStreaming>, MockTransport) {
        let mock = MockTransport()
        let reactor = Reactor(
            configuration: ReactorConfiguration(modelName: "sana-streaming"),
            transportFactory: { _, _, _ in mock }
        )
        let session = ReactorSession<SanaStreaming>(reactor: reactor)
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
