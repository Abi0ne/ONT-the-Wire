import Foundation

public enum ConnectionState: Equatable, Sendable {
    case idle
    case preparing
    case searchingServer
    case authenticating
    case configuringNetwork
    case connected(addresses: [String])
    case disconnecting
    case failed(String)

    public var title: String {
        switch self {
        case .idle: "Inattiva"
        case .preparing: "Avvio"
        case .searchingServer: "Ricerca del server PPPoE"
        case .authenticating: "Autenticazione"
        case .configuringNetwork: "Configurazione indirizzo IP"
        case .connected: "Connessa"
        case .disconnecting: "Disconnessione"
        case .failed: "Errore"
        }
    }

    /// True while a connect/disconnect operation is running and the user
    /// should not be able to start another one.
    public var isBusy: Bool {
        switch self {
        case .idle, .connected, .failed: false
        default: true
        }
    }

    /// States that session events must not move away from.
    public var isTerminal: Bool {
        switch self {
        case .idle, .disconnecting, .failed: true
        default: false
        }
    }

    public var isSessionActive: Bool {
        switch self {
        case .searchingServer, .authenticating, .configuringNetwork, .connected: true
        default: false
        }
    }
}
