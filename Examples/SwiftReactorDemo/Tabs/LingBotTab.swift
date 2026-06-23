import SwiftUI
import SwiftReactor
import SwiftReactorDemoSupport

/// LingBot tab — action-controlled world generation.
///
/// Specialty showcased here:
///
///   • **Sticky inputs.** Movement / look buttons hold state — clicking
///     "Forward" then "Look Left" doesn't issue a series of one-frame
///     events; it sets two persistent fields that the model reads on
///     every chunk.
///   • **Composite action snapshot.** The server emits each chunk's
///     `activeAction` as a `+`-joined string (`"forward+left"`); the UI
///     mirrors `snapshot.currentAction` so you can verify what the
///     model actually applied.
///   • **Rotation speed.** Slider for `set_rotation_speed_deg`
///     (0.0–30.0); the underlying wire key is exactly that, including
///     the `_deg` suffix.
struct LingBotTab: View {
    @EnvironmentObject private var settings: DemoSettings
    @State private var session = LingBotSession()
    @State private var connectError: String?
    @State private var prompt: String = "Medieval village at dusk, cobblestone streets, glowing windows, smoke curling from chimneys."
    @State private var refImageData: Data?
    @State private var refImageURL: URL?
    @State private var fileRef: FileRef?
    @State private var uploadingImage = false
    @State private var rotationSpeed: Double = 5.0
    @State private var chunkLog: [String] = []

    /// Derived from the server snapshot via the testable helper in
    /// `SwiftReactorDemoSupport`. See `PreflightGates` for why we
    /// never cache `conditions_ready` event flags.
    private var conditionsReady: Bool {
        PreflightGates.lingBotConditionsReady(snapshot: session.snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                ReactorView(reactor: session.reactor)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                actionSnapshot
                CommandErrorBanner(error: session.lastCommandError.map { CommandErrorView(msg: $0) })

                preflight
                conditioning
                joystick
                chunkLogView
            }
            .padding(.horizontal, 4)
        }
        .task {
            session.onChunkComplete { c in
                chunkLog.insert(
                    "chunk \(c.chunkIndex) action=\(c.activeAction)",
                    at: 0
                )
                if chunkLog.count > 50 { chunkLog.removeLast() }
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
                    .init("Seed image picked + uploaded",
                          met: fileRef != nil,
                          hint: "Pick an image, then click Upload"),
                    .init("Prompt typed",
                          met: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          hint: "Type a world description"),
                    .init("setPrompt + setImage sent (server confirmed)",
                          met: conditionsReady,
                          hint: "Click `setPrompt + setImage + start` — server emits conditions_ready"),
                ]
        )
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("LingBot").font(.title.weight(.semibold))
                Text("persistent action controls • virtual joystick")
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

    private var actionSnapshot: some View {
        HStack(spacing: 16) {
            Label("chunk \(session.snapshot?.currentChunk ?? 0)", systemImage: "square.stack.3d.up")
                .font(.callout.monospacedDigit())
            Divider().frame(height: 14)
            Label("action: \(session.snapshot?.currentAction ?? "still")", systemImage: "gamecontroller")
                .font(.callout.monospacedDigit())
            Spacer()
            Label("rot \(session.snapshot?.rotationSpeedDeg ?? rotationSpeed, format: .number.precision(.fractionLength(1)))°", systemImage: "rotate.3d")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var conditioning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Seed").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                referenceImagePicker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt").font(.callout.weight(.medium))
                    TextField("Type a world description…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...6)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button("setPrompt + setImage + start") {
                                Task { try? await sendOpener() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSendOpener)
                            Spacer()
                            Button("reset") {
                                Task { try? await session.reset() }
                            }
                            .disabled(session.status != .ready)
                            .tint(.secondary)
                        }
                        DisabledReason(reason: openerDisabledReason)
                    }
                }
            }
        }
    }

    private var referenceImagePicker: some View {
        VStack(spacing: 6) {
            if let refImageData,
               let nsImage = NSImage(data: refImageData) {
                Image(nsImage: nsImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 200, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Rectangle()
                    .fill(.tertiary.opacity(0.4))
                    .frame(width: 200, height: 120)
                    .overlay(Text("Pick a seed image").font(.callout).foregroundStyle(.secondary))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Pick image…") { pickImage() }
                Button { Task { await upload() } } label: {
                    if uploadingImage { ProgressView().controlSize(.mini) } else { Text("Upload") }
                }
                .disabled(refImageData == nil || session.status != .ready || uploadingImage)
            }
            if let fileRef {
                Text("ref: \(fileRef.uploadId.prefix(18))…")
                    .font(.caption.monospaced()).foregroundStyle(.green)
            }
        }
    }

    private var joystick: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Controls (sticky — set once, model applies every chunk)").font(.headline)

            HStack(alignment: .top, spacing: 32) {
                VStack(spacing: 4) {
                    Text("Movement").font(.callout.weight(.medium))
                    HStack { Spacer(); movementButton(.forward, "↑"); Spacer() }
                    HStack(spacing: 4) {
                        movementButton(.strafeLeft, "←")
                        movementButton(.idle, "•")
                        movementButton(.strafeRight, "→")
                    }
                    HStack { Spacer(); movementButton(.back, "↓"); Spacer() }
                }

                VStack(spacing: 4) {
                    Text("Look").font(.callout.weight(.medium))
                    HStack { Spacer(); lookVerticalButton(.up, "▲"); Spacer() }
                    HStack(spacing: 4) {
                        lookHorizontalButton(.left, "◀")
                        lookHorizontalButton(.idle, "•")
                        lookHorizontalButton(.right, "▶")
                    }
                    HStack { Spacer(); lookVerticalButton(.down, "▼"); Spacer() }
                    Button("Idle look") {
                        Task {
                            try? await session.setLookHorizontal(.idle)
                            try? await session.setLookVertical(.idle)
                        }
                    }
                    .controlSize(.small)
                    .disabled(session.status != .ready)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Rotation speed (deg/chunk)").font(.callout.weight(.medium))
                    Slider(value: $rotationSpeed, in: 0.0...30.0, step: 0.5)
                        .frame(width: 220)
                    Text("\(rotationSpeed, format: .number.precision(.fractionLength(1)))°")
                        .font(.callout.monospacedDigit())
                    Button("apply") {
                        Task { try? await session.setRotationSpeed(degreesPerChunk: rotationSpeed) }
                    }
                    .disabled(session.status != .ready)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var chunkLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk log").font(.headline)
            if chunkLog.isEmpty {
                Text("(no chunks yet — pick a seed image, upload, set prompt, hit start)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(chunkLog, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Gate logic

    private var canSendOpener: Bool {
        session.status == .ready
            && fileRef != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !session.hasStartedRun
    }

    private var openerDisabledReason: String? {
        if session.status != .ready { return "Connect first (top-right)." }
        if fileRef == nil { return "Pick a seed image and click Upload." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a world description in the prompt field."
        }
        if session.hasStartedRun { return "Run is live — use reset to start a new one." }
        return nil
    }

    // MARK: - Button factories

    private func movementButton(_ value: LingBot.Movement, _ label: String) -> some View {
        let active = session.snapshot?.movement == value.rawValue
        return Button(label) {
            Task { try? await session.setMovement(value) }
        }
        .frame(width: 48, height: 32)
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
        .disabled(session.status != .ready)
    }

    private func lookHorizontalButton(_ value: LingBot.LookHorizontal, _ label: String) -> some View {
        let active = session.snapshot?.lookHorizontal == value.rawValue
        return Button(label) {
            Task { try? await session.setLookHorizontal(value) }
        }
        .frame(width: 48, height: 32)
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
        .disabled(session.status != .ready)
    }

    private func lookVerticalButton(_ value: LingBot.LookVertical, _ label: String) -> some View {
        let active = session.snapshot?.lookVertical == value.rawValue
        return Button(label) {
            Task { try? await session.setLookVertical(value) }
        }
        .frame(width: 48, height: 32)
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
        .disabled(session.status != .ready)
    }

    // MARK: - Actions

    private func toggleConnection() async {
        if session.status == .disconnected {
            do {
                try await session.connect(jwt: settings.makeJWTSource())
                connectError = nil
            } catch {
                connectError = "\(error)"
            }
        } else {
            await session.disconnect()
            connectError = nil
            fileRef = nil
            chunkLog.removeAll()
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a seed image for LingBot"
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            refImageURL = url
            refImageData = data
            fileRef = nil
        }
    }

    private func upload() async {
        guard let data = refImageData, let url = refImageURL else { return }
        uploadingImage = true
        defer { uploadingImage = false }
        do {
            fileRef = try await session.uploadImage(
                data: data,
                name: url.lastPathComponent,
                mimeType: url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            )
        } catch {
            connectError = "upload failed: \(error)"
        }
    }

    private func sendOpener() async throws {
        guard let fileRef else { return }
        try await session.setPrompt(prompt)
        try await session.setImage(fileRef)
        // Wait for the server to confirm both hasPrompt and hasImage
        // before firing `start`. Without this, an auto-reset still
        // in flight (from a previous generation_complete) can race
        // start and the server emits `[start] No image set` even
        // though we just sent setImage.
        for _ in 0..<10 {
            if conditionsReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard conditionsReady else {
            throw NSError(domain: "LingBotTab", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Server didn't confirm hasPrompt && hasImage in time — try again."
            ])
        }
        try await session.start()
    }
}

private struct CommandErrorView: CustomStringConvertible {
    let msg: LingBot.CommandErrorMessage
    var description: String { "[\(msg.command)] \(msg.reason)" }
}
