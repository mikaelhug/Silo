import SwiftUI

/// A presentational row for a single installed runtime (Wine or GPTK): a default-state checkmark, the
/// title with optional warning/subtitle, and Set-default / remove actions. Plain data + closures only.
struct RuntimeInstallRow: View {
    let title: String
    let warning: String?
    let subtitle: String?
    let isDefault: Bool
    let canSetDefault: Bool
    let onSetDefault: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDefault ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let warning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if isDefault {
                Text("Default").font(.caption2).foregroundStyle(.green)
            } else {
                Button("Set default", action: onSetDefault).disabled(!canSetDefault)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}
