import SwiftUI
import SwiftReactor

/// Reusable status pill for each tab's connection bar. Reads
/// `ReactorStatus` and renders a colored badge so you can see at a
/// glance whether a tab is connected.
struct StatusBadge: View {
    let status: ReactorStatus
    let errorText: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .help(errorText ?? label)
    }

    private var color: Color {
        if errorText != nil { return .red }
        switch status {
        case .disconnected: return .gray
        case .connecting, .waiting: return .yellow
        case .ready: return .green
        }
    }

    private var label: String {
        if let errorText { return "error: " + errorText.prefix(40) + (errorText.count > 40 ? "…" : "") }
        return status.rawValue
    }
}

/// Reusable command-error banner — every typed wrapper exposes
/// `lastCommandError`; surface it consistently across tabs.
struct CommandErrorBanner<Err>: View where Err: CustomStringConvertible {
    let error: Err?

    var body: some View {
        if let error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error.description)
                    .font(.callout.monospaced())
                    .lineLimit(2)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
