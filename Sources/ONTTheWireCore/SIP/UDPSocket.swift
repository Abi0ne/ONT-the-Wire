import Darwin
import Foundation
import SystemConfiguration

/// An IPv4 address and UDP port.
struct UDPEndpoint: Hashable, Sendable, CustomStringConvertible {
    var host: String
    var port: UInt16

    var description: String { "\(host):\(port)" }

    fileprivate init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    init?(address: String, port: Int) {
        var probe = in_addr()
        guard inet_pton(AF_INET, address, &probe) == 1, (0...65535).contains(port) else { return nil }
        self.init(host: address, port: UInt16(port))
    }

    fileprivate init(_ raw: sockaddr_in) {
        var addr = raw.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
        self.init(host: String(cString: buffer), port: UInt16(bigEndian: raw.sin_port))
    }

    fileprivate var sockaddr: sockaddr_in {
        var raw = sockaddr_in()
        raw.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        raw.sin_family = sa_family_t(AF_INET)
        raw.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &raw.sin_addr)
        return raw
    }

    /// Resolves a host name (or IPv4 literal) with the system resolver.
    static func resolve(_ host: String, port: Int) async throws -> UDPEndpoint {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, String(port), &hints, &list)
            defer { if list != nil { freeaddrinfo(list) } }
            guard status == 0, let first = list, let address = first.pointee.ai_addr else {
                throw SIPError.dnsFailed(host)
            }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            return UDPEndpoint(raw)
        }.value
    }

    /// The local address the routing table uses to reach `remote`, through a
    /// given interface or the Mac's primary route.
    static func localAddress(toward remote: UDPEndpoint, interface: String?) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if let interface, !UDPSocket.bind(fd, toInterface: interface) { return nil }
        var target = remote.sockaddr
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return named == 0 ? UDPEndpoint(local).host : nil
    }
}

/// A UDP socket, optionally tied to one interface (IP_BOUND_IF), delivering
/// datagrams on a dispatch queue.
final class UDPSocket: @unchecked Sendable {
    let localPort: UInt16
    private let fd: Int32
    private let source: DispatchSourceRead

    /// Binds to `preferredPort` (0: any) or, if busy, to a free port.
    init(interface: String?, preferredPorts: [UInt16], queue: DispatchQueue,
         onReceive: @escaping (Data, UDPEndpoint) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SIPError.socket(errno) }
        if let interface, !Self.bind(fd, toInterface: interface) {
            Darwin.close(fd)
            throw SIPError.interfaceUnavailable(interface)
        }
        var bound: UInt16?
        for port in preferredPorts + [0] {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                var local = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                bound = UInt16(bigEndian: local.sin_port)
                break
            }
        }
        guard let bound else {
            let error = errno
            Darwin.close(fd)
            throw SIPError.socket(error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        self.fd = fd
        self.localPort = bound
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [fd] in
            var buffer = [UInt8](repeating: 0, count: 65_535)
            while true {
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                    }
                }
                guard count > 0 else { break }
                onReceive(Data(buffer[0..<count]), UDPEndpoint(from))
            }
        }
        source.setCancelHandler { [fd] in Darwin.close(fd) }
        source.resume()
    }

    deinit { source.cancel() }

    func send(_ data: Data, to endpoint: UDPEndpoint) {
        var address = endpoint.sockaddr
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() { source.cancel() }

    fileprivate static func bind(_ fd: Int32, toInterface name: String) -> Bool {
        var index = if_nametoindex(name)
        guard index != 0 else { return false }
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }
}

/// A network the SIP tests can use: any interface with an IPv4 address.
public struct SIPNetworkLink: Identifiable, Hashable, Sendable {
    public var id: String { bsdName }
    public let bsdName: String
    public let displayName: String
    public let address: String

    /// Current IPv4 interfaces (PPPoE, Wi-Fi, Ethernet…), loopback and
    /// link-local excluded.
    public static func current() -> [SIPNetworkLink] {
        var names: [String: String] = [:]
        for iface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                names[bsd] = name
            }
        }

        var links: [SIPNetworkLink] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UDPEndpoint(raw).host
            guard !ip.hasPrefix("169.254."), !links.contains(where: { $0.bsdName == String(cString: entry.ifa_name) }) else { continue }
            let bsd = String(cString: entry.ifa_name)
            let name = bsd.hasPrefix("ppp") ? "PPPoE" : (names[bsd] ?? bsd)
            links.append(SIPNetworkLink(bsdName: bsd, displayName: name, address: ip))
        }
        return links.sorted { lhs, rhs in
            // PPP links first, then by interface name.
            if lhs.bsdName.hasPrefix("ppp") != rhs.bsdName.hasPrefix("ppp") { return lhs.bsdName.hasPrefix("ppp") }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }
}

enum SIPError: LocalizedError {
    case dnsFailed(String)
    case socket(Int32)
    case interfaceUnavailable(String)
    case noRoute(String)

    var errorDescription: String? {
        switch self {
        case .dnsFailed(let host): "Impossibile risolvere il server SIP “\(host)”: controlla il nome e la connessione."
        case .socket(let code): "Impossibile aprire la porta UDP (\(String(cString: strerror(code))))."
        case .interfaceUnavailable(let name): "La rete \(name) non è più disponibile."
        case .noRoute(let target): "Nessuna rete raggiunge \(target)."
        }
    }
}
