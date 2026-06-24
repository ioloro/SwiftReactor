import SwiftUI
import SwiftReactor
import SwiftReactorDemoSupport
import UniformTypeIdentifiers

/// SANA-Streaming tab — real-time video-to-video editing.
///
/// Specialty showcased here:
///
///   • **Source clip upload.** `uploadVideo(...)` + `setVideo(ref)`,
///     showing the file-mode end-to-end flow.
///   • **Anchor re-grounding.** A slider that adjusts
///     `setAnchorInterval(chunks:)` live (default 20, 0 disables).
///     `anchored` events appear in the log as the model re-references
///     the source.
///   • **Mid-edit prompt updates.** Change the editing instruction
///     mid-stream; it takes effect at the next chunk boundary.
///   • **Live mode disabled.** `setMode(.live)` throws
///     `liveModeNotYetSupported` until `publishTrack` lands in v0.3 —
///     the demo surfaces this honestly rather than pretending.
struct SanaStreamingTab: View {
    @EnvironmentObject private var settings: DemoSettings
    @State private var session = ReactorSession<SanaStreaming>()
    @State private var connectError: String?
    @State private var prompt: String = "Turn it into a hand-painted watercolor with warm light."
    @State private var videoData: Data?
    @State private var videoURL: URL?
    @State private var fileRef: FileRef?
    @State private var uploadingVideo = false
    @State private var anchorInterval: Double = 20
    @State private var liveModeAttempted = false
    @State private var eventLog: [String] = []

    /// Derived from the server snapshot via the testable helpers in
    /// `SwiftReactorDemoSupport`. See `PreflightGates` for why we
    /// never cache `conditions_ready` event flags.
    private var conditionsReady: Bool {
        PreflightGates.sanaConditionsReady(snapshot: session.snapshot)
    }
    private var modeSet: Bool {
        PreflightGates.sanaModeSet(snapshot: session.snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                ReactorView(reactor: session.reactor)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                snapshotBar
                CommandErrorBanner(error: session.lastCommandError.map { CommandErrorView(msg: $0) })

                preflight
                modeAndSource
                steering
                eventLogView
            }
            .padding(.horizontal, 4)
        }
        .task {
            session.onChunkComplete { c in
                eventLog.insert("chunk \(c.chunkIndex) — \(c.activePrompt.prefix(60))", at: 0)
                trim()
            }
            session.onAnchored { a in
                eventLog.insert("⚓︎ re-anchored at chunk \(a.chunkIndex)", at: 0)
                trim()
            }
            session.onGenerationComplete { g in
                eventLog.insert("✅ generation_complete (\(g.totalChunks) chunks)", at: 0)
                trim()
            }
        }
    }

    private var preflight: some View {
        Preflight(
            title: session.hasStartedRun ? "Run live" : "Before start",
            steps: session.hasStartedRun
                ? [.init("Run started", met: true)]
                : [
                    .init("Connected (status .ready)",
                          met: session.status == .ready,
                          hint: "Click Connect (top-right)"),
                    .init("Mode set to file",
                          met: modeSet,
                          hint: "Click `File` under Mode"),
                    .init("Source clip uploaded + setVideo sent",
                          met: fileRef != nil,
                          hint: "Pick MP4, then click Upload + setVideo"),
                    .init("Edit prompt typed",
                          met: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          hint: "Type an editing instruction below"),
                    .init("conditions_ready (server confirmed prompt + video)",
                          met: conditionsReady,
                          hint: "Send setPrompt — server emits conditions_ready"),
                ]
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SANA-Streaming").font(.title.weight(.semibold))
                Text("video-to-video editing • anchor re-grounding")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: session.status, errorText: connectError)
            Button(session.status == .ready ? "Disconnect" : "Connect") {
                Task { await toggleConnection() }
            }
        }
    }

    private var snapshotBar: some View {
        HStack(spacing: 16) {
            Label("chunk \(session.snapshot?.currentChunk ?? 0)", systemImage: "square.stack.3d.up")
                .font(.callout.monospacedDigit())
            Divider().frame(height: 14)
            Label("mode: \(session.snapshot?.mode ?? "—")", systemImage: "film")
                .font(.callout.monospacedDigit())
            Divider().frame(height: 14)
            Label("anchor every \(session.snapshot?.anchorInterval ?? Int(anchorInterval))",
                  systemImage: "anchor")
                .font(.callout.monospacedDigit())
            Spacer()
            Label(session.snapshot?.hasVideo == true ? "video set" : "no video",
                  systemImage: "video")
                .font(.caption)
                .foregroundStyle(session.snapshot?.hasVideo == true ? .green : .secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var modeAndSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source").font(.headline)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode").font(.callout.weight(.medium))
                    HStack {
                        fileModeButton
                        Button("Live (v0.3)") {
                            liveModeAttempted = true
                            Task { _ = try? await session.setMode(.live) }
                        }
                        .disabled(session.status != .ready)
                    }
                    if liveModeAttempted {
                        Label("Live camera input is a v0.2 stub (publishTrack); SDK rejects it locally so we don't lie about what works.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Source clip").font(.callout.weight(.medium))
                    HStack {
                        Button("Pick MP4…") { pickVideo() }
                        Button {
                            Task { await uploadAndSet() }
                        } label: {
                            if uploadingVideo { ProgressView().controlSize(.mini) } else { Text("Upload + setVideo") }
                        }
                        .disabled(videoData == nil || session.status != .ready || uploadingVideo)
                    }
                    if let videoURL {
                        Text(videoURL.lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    if let fileRef {
                        Text("ref: \(fileRef.uploadId.prefix(18))… (\(fileRef.size) bytes)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var steering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editing instruction").font(.headline)
            TextField("Type an editing instruction…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Button("setPrompt + start") {
                        Task { try? await sendOpener() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSendOpener)

                    Button("setPrompt (mid-run)") {
                        Task { try? await session.setPrompt(prompt) }
                    }
                    .disabled(session.status != .ready || !session.hasStartedRun)

                    Spacer()

                    Button("reset") {
                        Task { try? await session.reset() }
                    }
                    .disabled(session.status != .ready)
                    .tint(.secondary)
                }
                DisabledReason(reason: openerDisabledReason)
            }

            HStack(spacing: 12) {
                Text("Anchor every").font(.callout)
                Slider(value: $anchorInterval, in: 0...40, step: 1)
                    .frame(maxWidth: 280)
                Text("\(Int(anchorInterval))").font(.callout.monospacedDigit()).frame(width: 28)
                Button("apply") {
                    Task { try? await session.setAnchorInterval(chunks: Int(anchorInterval)) }
                }
                .disabled(session.status != .ready)
            }
            Text("Lower anchor intervals keep edits faithful to the source; higher values let the model drift creatively. 0 disables re-anchoring entirely.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eventLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Event log").font(.headline)
            if eventLog.isEmpty {
                Text("(no events yet — pick a clip, upload, set prompt, start)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(eventLog, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var fileModeButton: some View {
        if modeSet {
            Button("File") {
                Task { try? await session.setMode(.file) }
            }
            .disabled(session.status != .ready)
        } else {
            Button("File") {
                Task { try? await session.setMode(.file) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.status != .ready)
        }
    }

    // MARK: - Gate logic

    private var canSendOpener: Bool {
        session.status == .ready
            && fileRef != nil
            && modeSet
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.hasStartedRun
    }

    private var openerDisabledReason: String? {
        if session.status != .ready { return "Connect first (top-right)." }
        if !modeSet { return "Click `File` under Mode." }
        if fileRef == nil { return "Pick an MP4 and click `Upload + setVideo`." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type an editing instruction."
        }
        if session.hasStartedRun { return "Run is live — use reset to start a new one." }
        return nil
    }

    // MARK: - Actions

    private func toggleConnection() async {
        if session.status == .disconnected {
            do {
                try await session.reactor.connect(jwt: settings.makeJWTSource())
                connectError = nil
            } catch {
                connectError = "\(error)"
            }
        } else {
            await session.disconnect()
            connectError = nil
            fileRef = nil
            eventLog.removeAll()
        }
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.message = "Pick an MP4 clip to edit"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            videoURL = url
            videoData = data
            fileRef = nil
        }
    }

    private func uploadAndSet() async {
        guard let data = videoData, let url = videoURL else { return }
        uploadingVideo = true
        defer { uploadingVideo = false }
        do {
            let ref = try await session.uploadVideo(
                data: data,
                name: url.lastPathComponent,
                mimeType: "video/mp4"
            )
            fileRef = ref
            try await session.setMode(.file)
            try await session.setVideo(ref)
        } catch {
            connectError = "upload/setVideo failed: \(error)"
        }
    }

    private func sendOpener() async throws {
        try await session.setPrompt(prompt)
        try await session.setAnchorInterval(chunks: Int(anchorInterval))
        // Wait for the server to confirm hasVideo && hasPrompt before
        // firing start, so an auto-reset in flight from a prior run
        // can't race start.
        for _ in 0..<10 {
            if conditionsReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard conditionsReady else {
            throw NSError(domain: "SanaStreamingTab", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Server didn't confirm hasVideo && hasPrompt in time — try again."
            ])
        }
        try await session.start()
    }

    private func trim() {
        if eventLog.count > 50 { eventLog.removeLast() }
    }
}

private struct CommandErrorView: CustomStringConvertible {
    let msg: SanaStreaming.CommandErrorMessage
    var description: String { "[\(msg.command)] \(msg.reason)" }
}
