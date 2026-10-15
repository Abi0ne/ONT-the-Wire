import AppKit
import ONTTheWireCore
import SwiftUI

struct LogView: View {
    let log: LogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.plainText, forType: .string)
                }
                .disabled(log.entries.isEmpty)
                Button("Pulisci") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            .controlSize(.small)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            LogRow(entry: entry).id(entry.id)
                            Divider().opacity(0.4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay {
                    if log.entries.isEmpty {
                        Text("Nessun evento").foregroundStyle(.tertiary)
                    }
                }
                .onChange(of: log.entries.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.callout)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.level {
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}
