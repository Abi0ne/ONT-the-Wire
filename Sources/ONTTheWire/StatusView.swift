import ONTTheWireCore
import SwiftUI

struct StatusView: View {
    let state: ConnectionState
    let onDismissError: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(color)
                .frame(width: 32)
                .symbolEffect(.pulse, isActive: state.isBusy || isConnecting)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.title3.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if case .failed = state {
                Button("OK", action: onDismissError)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var isConnecting: Bool {
        switch state {
        case .searchingServer, .authenticating, .configuringNetwork: true
        default: false
        }
    }

    private var symbol: String {
        switch state {
        case .idle: "network.slash"
        case .preparing: "lock"
        case .searchingServer: "magnifyingglass"
        case .authenticating: "key"
        case .configuringNetwork: "point.3.connected.trianglepath.dotted"
        case .connected: "checkmark.circle.fill"
        case .disconnecting: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .failed: .red
        case .idle: .secondary
        default: .orange
        }
    }

    private var detail: String? {
        switch state {
        case .idle: "Nessuna sessione PPPoE attiva."
        case .preparing: "Avvio della sessione PPPoE."
        case .searchingServer: "Invio delle richieste PPPoE sulla VLAN, in attesa di risposta tramite l’ONT."
        case .authenticating: "Server trovato, verifica delle credenziali."
        case .configuringNetwork: "Autenticazione riuscita, in attesa dell’indirizzo IP."
        case .connected(let addresses): "Indirizzo: \(addresses.joined(separator: ", "))"
        case .disconnecting: "Chiusura della sessione PPPoE."
        case .failed(let message): message
        }
    }
}
