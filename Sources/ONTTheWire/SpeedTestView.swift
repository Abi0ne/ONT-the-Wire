import ONTTheWireCore
import SwiftUI

/// Text speed test in the style of Ookla's Speedtest CLI: many parallel
/// streams on the PPP link, aggregated.
struct SpeedTestView: View {
    let controller: ConnectionController

    private var test: SpeedTest { controller.speedTest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Test di velocità")
                    .font(.headline)
                Spacer()
                Picker("Flussi", selection: Binding(get: { test.streams }, set: { test.streams = $0 })) {
                    ForEach(SpeedTest.streamChoices, id: \.self) { Text("\($0) flussi").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(test.isRunning)
                .help("Connessioni parallele: più flussi servono a saturare linee veloci")
                if test.isRunning {
                    Button("Interrompi") { test.cancel() }
                } else {
                    Button(test.result == nil ? "Avvia" : "Ripeti") { controller.startSpeedTest() }
                        .disabled(!controller.canRunSpeedTest)
                }
            }
            .controlSize(.small)

            Text(report)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(test.result == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = test.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var report: String {
        guard let result = test.result else {
            return controller.canRunSpeedTest
                ? "Misura ping, download e upload sulla linea PPPoE con più connessioni\nparallele verso più server (Cloudflare, Apple CDN, OVH)."
                : "Disponibile a connessione attiva."
        }
        let address = controller.details.localAddress.map { " · \($0)" } ?? ""
        var lines = [
            "Interfaccia  \(result.interface)\(address)",
            "     Flussi  \(result.streams) in parallelo",
        ]
        if let ping = result.pingMs {
            lines.append(String(format: "       Ping  %.1f ms   jitter %.1f ms", ping, result.jitterMs ?? 0))
        } else {
            lines.append("       Ping  \(bar(active: test.phase == .latency))")
        }
        lines.append("   Download  " + speedLine(result.downloadMbps, loaded: result.downloadLoadedLatencyMs, active: test.phase == .download))
        lines.append("     Upload  " + speedLine(result.uploadMbps, loaded: result.uploadLoadedLatencyMs, active: test.phase == .upload))
        if test.phase == .finished {
            if !result.downloadShare.isEmpty { lines.append("  Server ↓   " + share(result.downloadShare)) }
            if !result.uploadShare.isEmpty { lines.append("  Server ↑   " + share(result.uploadShare)) }
            for warning in result.warnings { lines.append("  Avviso     " + warning) }
        }
        return lines.joined(separator: "\n")
    }

    private func speedLine(_ value: Double?, loaded: Double?, active: Bool) -> String {
        if active {
            let live = test.liveMbps.map { String(format: "%9.2f Mbps", $0) } ?? ""
            return "\(bar(active: true)) \(live)"
        }
        guard let value else { return test.isRunning ? "in attesa" : "—" }
        let latency = loaded.map { String(format: "   latenza sotto carico %.0f ms", $0) } ?? ""
        return String(format: "%9.2f Mbps", value) + latency
    }

    /// Text progress bar for the running phase.
    private func bar(active: Bool) -> String {
        guard active else { return "in attesa" }
        let width = 20
        let filled = Int((test.progress * Double(width)).rounded())
        return "[" + String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled) + "]"
    }

    private func share(_ values: [String: Double]) -> String {
        values.sorted { $0.value > $1.value }
            .map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }
            .joined(separator: " · ")
    }
}
