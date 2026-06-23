import SwiftUI
import SwiftReactor
import SwiftReactorDemoSupport

/// LongLive-v2 tab — the multi-shot story.
///
/// Specialty showcased here:
///
///   • **Opener-once.** `setShot` then `start` exactly once; the
///     wrapper rejects re-`start` locally.
///   • **Shots vs. cuts.** One prompt field, two apply buttons — soft
///     `setShot` (same scene, memory preserved) vs hard `sceneCut`
///     (new world, 48-chunk budget reset).
///   • **Scheduling.** Plant a beat at `sessionChunk + N` via
///     `scheduleShot` / `scheduleSceneCut`.
///   • **Scene budget.** Live meter against the 48-chunk per-scene
///     cap so you see the cut-or-die boundary.
struct LongLiveTab: View {
    @EnvironmentObject private var settings: DemoSettings
    @State private var session = LongLiveV2Session()
    @State private var connectError: String?
    @State private var prompt: String = "A cinematic aerial flyover of a sun-drenched coastal cliff, slow drone push-in."
    @State private var scheduleOffset: Int = 5
    @State private var chunkLog: [String] = []

    /// Derived from the server snapshot via the testable helper in
    /// `SwiftReactorDemoSupport`. We deliberately do NOT cache a local
    /// `hasSentSetShot` flag: after `generation_complete + auto-reset`,
    /// the server clears `hasPrompt` but a cached flag would stay
    /// `true`, lying to the user that the preflight was satisfied and
    /// letting `start` ship into a `[start] No prompt set` rejection.
    private var openerReady: Bool {
        PreflightGates.longLiveOpenerReady(snapshot: session.snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ReactorView(reactor: session.reactor)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                budgetMeter
                CommandErrorBanner(error: session.lastCommandError.map { CommandErrorView(msg: $0) })

                preflight
                promptAndActions
                chunkLogView
            }
            .padding(.horizontal, 4)
        }
        .task {
            session.onChunkComplete { c in
                chunkLog.insert(
                    "chunk #\(c.chunkIndex) (session #\(c.sessionChunk)) — \(c.activePrompt.prefix(60))",
                    at: 0
                )
                if chunkLog.count > 50 { chunkLog.removeLast() }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("LongLive-v2").font(.title.weight(.semibold))
                Text("multi-shot real-time video • 48-chunk per-scene budget")
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

    private var budgetMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            let scene = session.snapshot?.currentChunk ?? 0
            let total = session.snapshot?.sessionChunk ?? 0
            HStack {
                Text("scene \(scene)/48").font(.callout.monospacedDigit())
                Spacer()
                Text("session \(total)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(scene), total: 48)
                .tint(scene >= 40 ? .orange : .accentColor)
            if scene >= 40 {
                Label("scene auto-completes at 48 — sceneCut to extend", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var preflight: some View {
        Preflight(
            title: session.hasStartedRun ? "Run live" : "Before start",
            steps: session.hasStartedRun
                ? [
                    .init("Run started", met: true),
                ]
                : [
                    .init("Connected (status .ready)",
                          met: session.status == .ready,
                          hint: "Click Connect (top-right)"),
                    .init("Prompt typed",
                          met: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          hint: "Type a shot description below"),
                    .init("setShot sent (server-acknowledged)",
                          met: openerReady,
                          hint: "Click setShot — server must report hasPrompt before start"),
                ]
        )
    }

    @ViewBuilder
    private var promptAndActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(.headline)
            TextField("Type a shot description…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            if session.hasStartedRun {
                steeringControls
            } else {
                openerControls
            }
        }
    }

    private var openerControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button("setShot") {
                    Task { try? await session.setShot(prompt: prompt) }
                }
                .disabled(!canSendSetShotForOpener)

                Button("start") {
                    Task {
                        do {
                            try await session.start()
                        } catch {
                            connectError = "start failed: \(error)"
                        }
                    }
                }
                .disabled(!canStart)

                Spacer()

                Button("setShot + start") {
                    Task { try? await sendOpener() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSendOpenerCombined)
            }
            DisabledReason(reason: openerDisabledReason)
        }
    }

    private var steeringControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button("setShot (soft)") {
                    Task { try? await session.setShot(prompt: prompt) }
                }
                Button("sceneCut (hard)") {
                    Task { try? await session.sceneCut(prompt: prompt) }
                }
                Spacer()
                Stepper(value: $scheduleOffset, in: 1...30) {
                    Text("+\(scheduleOffset)").font(.callout.monospacedDigit())
                }
                .labelsHidden()
                Text("+\(scheduleOffset)").font(.callout.monospacedDigit()).frame(width: 32)
                Button("scheduleShot") {
                    let chunk = (session.snapshot?.sessionChunk ?? 0) + scheduleOffset
                    Task { try? await session.scheduleShot(prompt: prompt, atSessionChunk: chunk) }
                }
                Button("reset") {
                    Task { try? await session.reset() }
                }
                .tint(.secondary)
            }
            .disabled(session.status != .ready)
            Text("Soft `setShot` preserves the scene; hard `sceneCut` resets the per-scene 48-chunk budget. `reset` ends the run so you can start a new one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chunkLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chunk log").font(.headline)
            if chunkLog.isEmpty {
                Text("(no chunks yet — connect, type a prompt, click setShot + start)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chunkLog, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Gate logic

    private var canSendSetShotForOpener: Bool {
        session.status == .ready
            && !session.hasStartedRun
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canStart: Bool {
        session.status == .ready && !session.hasStartedRun && openerReady
    }

    private var canSendOpenerCombined: Bool {
        canSendSetShotForOpener
    }

    private var openerDisabledReason: String? {
        if session.status != .ready { return "Connect first (top-right)." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Type a shot description in the prompt field."
        }
        if session.hasStartedRun { return "Already started — use reset to send a new opener." }
        return nil
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
            chunkLog.removeAll()
        }
    }

    private func sendOpener() async throws {
        try await session.setShot(prompt: prompt)
        // Wait for the server to confirm `hasPrompt` before firing
        // `start` — without this, an auto-reset still in flight from
        // a previous `generation_complete` can race start and the
        // server emits `[start] No prompt set` even though we just
        // sent setShot.
        for _ in 0..<10 {
            if openerReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard openerReady else {
            throw NSError(domain: "LongLiveTab", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Server didn't confirm hasPrompt in time — click setShot again."
            ])
        }
        try await session.start()
    }
}

private struct CommandErrorView: CustomStringConvertible {
    let msg: LongLiveV2.CommandErrorMessage
    var description: String { "[\(msg.command)] \(msg.reason)" }
}
