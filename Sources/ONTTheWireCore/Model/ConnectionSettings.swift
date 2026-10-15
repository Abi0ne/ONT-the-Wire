import Foundation

/// User-editable connection parameters, never persisted. The password is kept
/// separately, only in memory.
public struct ConnectionSettings: Equatable, Sendable {
    public static let vlanRange = 1...4094

    public var interfaceBSDName: String?
    public var vlanIDText: String
    public var username: String
    /// Makes the PPP link the primary service (default route and DNS) while
    /// it is up.
    public var useAsPrimary: Bool

    public init(
        interfaceBSDName: String? = nil,
        vlanIDText: String = "",
        username: String = "",
        useAsPrimary: Bool = false
    ) {
        self.interfaceBSDName = interfaceBSDName
        self.vlanIDText = vlanIDText
        self.username = username
        self.useAsPrimary = useAsPrimary
    }

    /// The 802.1Q tag; nil when the field is empty (untagged frames) or invalid.
    public var vlanID: Int? {
        let trimmed = vlanIDText.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), Self.vlanRange.contains(value) else { return nil }
        return value
    }
}

public enum SettingsProblem: Equatable, Sendable {
    case noInterface
    case interfaceMissing
    case linkDown
    case vlanInvalid
    case usernameEmpty
    case passwordEmpty

    public var message: String {
        switch self {
        case .noInterface: "Seleziona l’adattatore Ethernet collegato all’ONT."
        case .interfaceMissing: "L’adattatore selezionato non è più presente: ricollegalo o scegline un altro."
        case .linkDown: "Il collegamento Ethernet non è attivo: controlla il cavo e che l’ONT sia acceso."
        case .vlanInvalid: "Il VLAN ID deve essere un numero intero tra 1 e 4094."
        case .usernameEmpty: "Inserisci lo username PPPoE."
        case .passwordEmpty: "Inserisci la password PPPoE."
        }
    }
}

public enum SettingsValidator {
    /// Returns every problem that prevents connecting, in display order.
    public static func problems(
        settings: ConnectionSettings,
        password: String,
        availableInterfaces: [EthernetInterface]
    ) -> [SettingsProblem] {
        var result: [SettingsProblem] = []
        if let bsd = settings.interfaceBSDName {
            if let iface = availableInterfaces.first(where: { $0.bsdName == bsd }) {
                if !iface.linkActive { result.append(.linkDown) }
            } else {
                result.append(.interfaceMissing)
            }
        } else {
            result.append(.noInterface)
        }
        if !settings.vlanIDText.trimmingCharacters(in: .whitespaces).isEmpty, settings.vlanID == nil {
            result.append(.vlanInvalid)
        }
        if settings.username.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(.usernameEmpty)
        }
        if password.isEmpty {
            result.append(.passwordEmpty)
        }
        return result
    }
}
