import Foundation
import Observation
import SystemConfiguration

public struct EthernetInterface: Identifiable, Hashable, Sendable {
    public var id: String { bsdName }
    public let bsdName: String
    public let displayName: String
    public let linkActive: Bool

    public init(bsdName: String, displayName: String, linkActive: Bool) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.linkActive = linkActive
    }
}

/// Lists the physical Ethernet interfaces that macOS can put a VLAN on, and
/// keeps their link state current by watching the dynamic store.
@MainActor
@Observable
public final class InterfaceCatalog {
    public private(set) var interfaces: [EthernetInterface] = []

    @ObservationIgnored private var store: SCDynamicStore?
    @ObservationIgnored public var onLinkChange: ((_ bsdName: String, _ active: Bool) -> Void)?

    public init() {
        startMonitoring()
        refresh()
    }

    public func interface(named bsdName: String?) -> EthernetInterface? {
        guard let bsdName else { return nil }
        return interfaces.first { $0.bsdName == bsdName }
    }

    public func refresh() {
        let previous = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.bsdName, $0.linkActive) })
        let physical = SCVLANInterfaceCopyAvailablePhysicalInterfaces() as? [SCNetworkInterface] ?? []
        let updated: [EthernetInterface] = physical.compactMap { iface in
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { return nil }
            let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? bsd
            return EthernetInterface(bsdName: bsd, displayName: name, linkActive: linkActive(bsd))
        }
        .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        interfaces = updated

        for iface in updated where previous[iface.bsdName] != iface.linkActive {
            onLinkChange?(iface.bsdName, iface.linkActive)
        }
        for (bsd, wasActive) in previous where wasActive && !updated.contains(where: { $0.bsdName == bsd }) {
            onLinkChange?(bsd, false)
        }
    }

    private func linkActive(_ bsdName: String) -> Bool {
        guard let store else { return false }
        let key = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
            nil, kSCDynamicStoreDomainState, bsdName as CFString, kSCEntNetLink)
        let value = SCDynamicStoreCopyValue(store, key) as? [String: Any]
        return value?[kSCPropNetLinkActive as String] as? Bool ?? false
    }

    private func startMonitoring() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let catalog = Unmanaged<InterfaceCatalog>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { catalog.refresh() }
        }
        guard let store = SCDynamicStoreCreate(nil, "ONTTheWire.interfaces" as CFString, callback, &context) else {
            return
        }
        let listKey = SCDynamicStoreKeyCreateNetworkInterface(nil, kSCDynamicStoreDomainState)
        let linkPattern = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
            nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetLink)
        SCDynamicStoreSetNotificationKeys(store, [listKey] as CFArray, [linkPattern] as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        self.store = store
    }
}
