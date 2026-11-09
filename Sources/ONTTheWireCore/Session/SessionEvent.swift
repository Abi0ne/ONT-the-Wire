import Foundation

/// Something that happened during a PPPoE session, decoded from the log lines
/// written by pppoe-relay and the root supervisor.
public enum SessionEvent: Equatable, Sendable {
    case discoveryStarted(interface: String, mac: String, vlan: Int?)
    case serverOffered(mac: String, acName: String)
    case sessionOpened(id: Int, acMAC: String)
    case noServer
    case discoveryError(String)
    case serverClosedSession
    case linkInterface(String)
    case authenticating(method: String)
    case authenticated
    case authenticationFailed
    case localAddress(String)
    case remoteAddress(String)
    case dnsServer(String)
    case primaryPublished
    case echoTimeout
    case peerTerminated
    /// Packet counters at the end of the session, already worded for the log.
    case statistics(String)
    /// The root supervisor never started; carries its own log, if any.
    case supervisorFailed(String)
}

/// Turns relay.log lines into `SessionEvent`s. They look like
/// `11:20:43 pppoe-relay: STATUS pado <mac> ac="X" service=""`.
public enum SessionLogParser {
    public static func parseRelayLine(_ line: String) -> SessionEvent? {
        guard let range = line.range(of: "STATUS ") else { return nil }
        let body = String(line[range.upperBound...])
        let words = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let kind = words.first else { return nil }

        switch kind {
        case "discovery" where words.count >= 3:
            let mac = value(of: "mac", in: words) ?? ""
            let vlan = value(of: "vlan", in: words).flatMap(Int.init)
            return .discoveryStarted(interface: words[1], mac: mac, vlan: vlan)
        case "pado" where words.count >= 2:
            return .serverOffered(mac: words[1], acName: quoted("ac", in: body) ?? "")
        case "session" where words.count >= 2:
            guard let id = Int(words[1]) else { return nil }
            return .sessionOpened(id: id, acMAC: value(of: "ac", in: words) ?? "")
        case "timeout":
            return .noServer
        case "error":
            return .discoveryError(words.dropFirst().joined(separator: " "))
        case "padt" where body.contains("concentratore"):
            return .serverClosedSession
        case "primary":
            return .primaryPublished
        case "auth" where words.count >= 2:
            return .authenticating(method: words[1])
        case "auth-ok":
            return .authenticated
        case "auth-failed":
            return .authenticationFailed
        case "interface" where words.count >= 2:
            return .linkInterface(words[1])
        case "local" where words.count >= 2:
            return .localAddress(words[1])
        case "remote" where words.count >= 2:
            return .remoteAddress(words[1])
        case "dns" where words.count >= 2:
            return .dnsServer(words[1])
        case "echo-timeout":
            return .echoTimeout
        case "lcp-terminated":
            return .peerTerminated
        case "stats" where words.count >= 2:
            return .statistics(words.dropFirst().joined(separator: " "))
        default:
            return nil
        }
    }

    private static func value(of key: String, in words: [String]) -> String? {
        words.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    private static func quoted(_ key: String, in body: String) -> String? {
        guard let start = body.range(of: key + "=\"") else { return nil }
        let rest = body[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

/// Splits appended file content into complete lines, keeping a trailing
/// partial line for the next read.
struct LineBuffer {
    private var pending = ""

    mutating func append(_ text: String) -> [String] {
        pending += text
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines.filter { !$0.isEmpty }
    }
}
