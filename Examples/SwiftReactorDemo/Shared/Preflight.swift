import SwiftUI

/// Reusable "what do you need to do next?" checklist. Each tab feeds in
/// its own gates; the view renders them with check / cross icons and
/// shows the first unmet step's `hint` inline so the user knows what
/// to click next.
struct Preflight: View {
    struct Step: Identifiable {
        // Stable identity — must NOT be a fresh UUID per construction,
        // otherwise the parent body's re-render churn causes ForEach to
        // unmount/remount every row on every keystroke, which on macOS
        // steals first-responder from sibling TextEditors.
        var id: String { label }
        let label: String
        let met: Bool
        /// One-line guidance shown next to the cross when this step
        /// hasn't been met yet. Should be actionable ("Click Upload",
        /// not "Image missing").
        let hint: String?

        init(_ label: String, met: Bool, hint: String? = nil) {
            self.label = label
            self.met = met
            self.hint = hint
        }
    }

    let title: String
    let steps: [Step]

    var allMet: Bool { steps.allSatisfy(\.met) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: allMet ? "checkmark.seal.fill" : "list.bullet.clipboard")
                    .foregroundStyle(allMet ? .green : .secondary)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if allMet {
                    Text("ready").font(.caption.monospaced()).foregroundStyle(.green)
                }
            }
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: step.met ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.met ? .green : .secondary)
                        .imageScale(.small)
                    Text(step.label)
                        .font(.callout)
                        .foregroundStyle(step.met ? .secondary : .primary)
                        .strikethrough(step.met)
                    if !step.met, let hint = step.hint {
                        Text("— \(hint)").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// "Why is this disabled?" line. Place under or next to a disabled
/// primary button so the user knows what to do instead of guessing.
struct DisabledReason: View {
    let reason: String?

    var body: some View {
        if let reason {
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
