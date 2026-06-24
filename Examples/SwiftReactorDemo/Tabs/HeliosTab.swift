import SwiftUI
import SwiftReactor
import SwiftReactorDemoSupport
import UniformTypeIdentifiers

/// Helios tab — image-conditioned real-time streaming.
///
/// Specialty showcased here:
///
///   • **Atomic conditioning.** `setConditioning(prompt:image:)` ships
///     prompt + image in one message, avoiding a transient frame
///     against mismatched inputs.
///   • **Scheduled prompts.** `schedulePrompt(_:atChunk:)` plants a
///     prompt change at a future cumulative chunk index.
///   • **Image strength.** Slider with the documented caveat that the
///     value doesn't take effect until the next `set_image` /
///     `set_conditioning`.
///   • **SR scale.** Off / 2x / 4x picker.
///   • **Preflight.** Helios requires *server-acknowledged* prompt +
///     image before `start` — the tab surfaces the
///     `conditions_ready` gate so you don't fire `start` into a
///     server-side `[start] No prompt set` rejection.
struct HeliosTab: View {
    @EnvironmentObject private var settings: DemoSettings
    @State private var session = ReactorSession<Helios>()
    @State private var connectError: String?
    @State private var prompt: String = "A misty fjord at golden hour, painterly atmosphere, gentle drone motion."
    @State private var refImageData: Data?
    @State private var refImageURL: URL?
    @State private var fileRef: FileRef?
    @State private var uploadingImage = false
    @State private var strength: Double = 0.5
    @State private var srScale: Helios.SRScale = .off
    @State private var schedulePromptText: String = "Storm rolls in, dark clouds, lightning flickers."
    @State private var scheduleOffset: Int = 6
    @State private var chunkLog: [String] = []

    /// Derived from the server snapshot via the testable helper in
    /// `SwiftReactorDemoSupport`. See `PreflightGates` for why we
    /// never cache `conditions_ready` event flags.
    private var conditionsReady: Bool {
        PreflightGates.heliosConditionsReady(snapshot: session.snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ReactorView(reactor: session.reactor)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                snapshotBar
                CommandErrorBanner(error: session.lastCommandError.map { CommandErrorView(msg: $0) })

                preflight
                conditioning
                steering
                chunkLogView
            }
            .padding(.horizontal, 4)
        }
        .task {
            session.onChunkComplete { c in
                chunkLog.insert("chunk \(c.chunkIndex) — \(c.activePrompt.prefix(60))", at: 0)
                if chunkLog.count > 50 { chunkLog.removeLast() }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Helios").font(.title.weight(.semibold))
                Text("image-conditioned • 33 frames/chunk • schedule prompts ahead")
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
            Label("strength \(strength, format: .number.precision(.fractionLength(2)))", systemImage: "dial.medium")
                .font(.callout.monospacedDigit())
            Divider().frame(height: 14)
            Label("sr \(srScale.rawValue)", systemImage: "arrow.up.right.square")
                .font(.callout.monospacedDigit())
            Spacer()
            Label(session.snapshot?.imageSet == true ? "image set" : "no image",
                  systemImage: "photo")
                .font(.caption)
                .foregroundStyle(session.snapshot?.imageSet == true ? .green : .secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var preflight: some View {
        Preflight(
            title: session.hasStartedRun ? "Run live" : "Before start",
            steps: session.hasStartedRun
                ? [
                    .init("Run started", met: true),
                    .init("conditions_ready (server)", met: conditionsReady,
                          hint: "Server hasn't confirmed yet — send setConditioning again if frames don't appear"),
                ]
                : [
                    .init("Connected (status .ready)",
                          met: session.status == .ready,
                          hint: "Click Connect (top-right)"),
                    .init("Image picked + uploaded",
                          met: fileRef != nil,
                          hint: "Pick an image, then click Upload"),
                    .init("Prompt typed",
                          met: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          hint: "Type a scene description below"),
                    .init("setConditioning sent (server-acknowledged)",
                          met: conditionsReady,
                          hint: "Click `setConditioning` — server must emit conditions_ready before start"),
                ]
        )
    }

    private var conditioning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conditioning").font(.headline)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reference image").font(.callout.weight(.medium))
                    referenceImagePicker
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt").font(.callout.weight(.medium))
                    TextField("Type a scene description…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(4...8)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Button("setConditioning") {
                        Task { try? await applyConditioning() }
                    }
                    .disabled(!canSendConditioning)
                    .help("Send prompt + image atomically. Server emits conditions_ready when accepted.")

                    if !session.hasStartedRun {
                        Button("start") {
                            Task { try? await session.start() }
                        }
                        .disabled(!canStart)
                        .help("Begin generation. Requires conditions_ready first.")
                    } else {
                        Spacer()
                    }

                    Spacer()

                    if !session.hasStartedRun {
                        Button("setConditioning + start") {
                            Task { try? await sendOpener() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart && !canSendConditioning)
                    }

                    Button("reset") {
                        Task { try? await session.reset() }
                    }
                    .disabled(session.status != .ready)
                    .tint(.secondary)
                }
                DisabledReason(reason: actionDisabledReason)
            }

            HStack(spacing: 12) {
                Text("strength").font(.callout)
                Slider(value: $strength, in: 0.0...1.0)
                Text("\(strength, format: .number.precision(.fractionLength(2)))").font(.callout.monospacedDigit())
                Button("apply") {
                    Task { try? await session.setImageStrength(strength) }
                }
                .disabled(session.status != .ready)

                Picker("SR", selection: $srScale) {
                    Text("off").tag(Helios.SRScale.off)
                    Text("2x").tag(Helios.SRScale.x2)
                    Text("4x").tag(Helios.SRScale.x4)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: srScale) { _, newValue in
                    Task { try? await session.setSRScale(newValue) }
                }
            }
            Text("`set_image_strength` only takes effect on the next `set_image` / `set_conditioning` — adjusting the slider alone won't change the live frame.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var referenceImagePicker: some View {
        VStack(spacing: 6) {
            if let refImageData,
               let nsImage = NSImage(data: refImageData) {
                Image(nsImage: nsImage)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 180, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Rectangle()
                    .fill(.tertiary.opacity(0.4))
                    .frame(width: 180, height: 110)
                    .overlay(Text("Pick a JPG/PNG").font(.callout).foregroundStyle(.secondary))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Pick image…") { pickImage() }
                Button(action: { Task { await upload() } }) {
                    if uploadingImage { ProgressView().controlSize(.mini) } else { Text("Upload") }
                }
                .disabled(refImageData == nil || session.status != .ready || uploadingImage)
            }
            if let fileRef {
                Text("ref: \(fileRef.uploadId.prefix(18))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
            }
        }
    }

    private var steering: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Schedule a prompt change").font(.headline)
            TextField("Future prompt to plant", text: $schedulePromptText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Stepper(value: $scheduleOffset, in: 1...30) {
                    Text("at +\(scheduleOffset) chunks").font(.callout.monospacedDigit())
                }
                .labelsHidden()
                Text("at +\(scheduleOffset) chunks").font(.callout.monospacedDigit())
                Spacer()
                Button("schedulePrompt") {
                    let chunk = (session.snapshot?.currentChunk ?? 0) + scheduleOffset
                    Task { try? await session.schedulePrompt(schedulePromptText, atChunk: chunk) }
                }
                .disabled(session.status != .ready || !session.hasStartedRun)
            }
        }
    }

    private var chunkLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk log").font(.headline)
            if chunkLog.isEmpty {
                Text("(no chunks yet — finish the preflight above)")
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

    private var canSendConditioning: Bool {
        session.status == .ready
            && fileRef != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canStart: Bool {
        session.status == .ready
            && !session.hasStartedRun
            && conditionsReady
    }

    private var actionDisabledReason: String? {
        if session.status != .ready { return "Connect first (top-right)." }
        if fileRef == nil { return "Pick an image and click Upload." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a scene description in the prompt field."
        }
        if !session.hasStartedRun && !conditionsReady {
            return "Click `setConditioning` first — the server must confirm `conditions_ready` before `start`."
        }
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
            chunkLog.removeAll()
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a reference image for Helios"
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
        try await applyConditioning()
        // Wait briefly for conditions_ready to arrive before firing start;
        // if it didn't, the disabled-reason will steer the user.
        for _ in 0..<10 {
            if conditionsReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if srScale != .off { try await session.setSRScale(srScale) }
        if conditionsReady {
            try await session.start()
        }
    }

    private func applyConditioning() async throws {
        guard let fileRef else { return }
        try await session.setConditioning(prompt: prompt, image: fileRef)
    }
}

private struct CommandErrorView: CustomStringConvertible {
    let msg: Helios.CommandErrorMessage
    var description: String { "[\(msg.command)] \(msg.reason)" }
}
