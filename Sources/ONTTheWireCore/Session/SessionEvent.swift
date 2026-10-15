import Foundation

/// Something that happened during a PPPoE session, decoded from the log lines
/// written by pppoe-relay, pppd and the root supervisor.
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
    case terminated
    /// The root supervisor never started; carries its own log, if any.
    case supervisorFailed(String)
}

/// Turns relay and pppd log lines into `SessionEvent`s.
///
/// relay.log lines look like `11:20:43 pppoe-relay: STATUS pado <mac> ac="X" service=""`;
/// pppd.log lines like `Thu Oct 15 11:20:47 2026 : CHAP authentication failed`.
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
        default:
            return nil
        }
    }

    public static func parsePPPDLine(_ line: String) -> SessionEvent? {
        // Relay stderr is mirrored into pppd.log; it is read from relay.log instead.
        if line.hasPrefix("pppoe-relay:") { return nil }
        let message: Substring
        if let range = line.range(of: " : ") {
            message = line[range.upperBound...]
        } else {
            message = Substring(line)
        }

        if let name = message.firstMatch(of: #/^Using interface (ppp\d+)/#) {
            return .linkInterface(String(name.1))
        }
        if message.hasPrefix("rcvd [CHAP Challenge") { return .authenticating(method: "CHAP") }
        if message.hasPrefix("sent [PAP AuthReq") { return .authenticating(method: "PAP") }
        if message.firstMatch(of: #/^(CHAP|PAP) authentication succeeded/#) != nil { return .authenticated }
        if message.firstMatch(of: #/^(CHAP|PAP) authentication failed/#) != nil { return .authenticationFailed }
        if let m = message.firstMatch(of: #/^local +IP address (\S+)/#) { return .localAddress(String(m.1)) }
        if let m = message.firstMatch(of: #/^remote +IP address (\S+)/#) { return .remoteAddress(String(m.1)) }
        if let m = message.firstMatch(of: #/^(?:primary|secondary) +DNS address (\S+)/#) { return .dnsServer(String(m.1)) }
        if message.hasPrefix("No response to") && message.contains("echo-requests") { return .echoTimeout }
        if message.hasPrefix("LCP terminated by peer") { return .peerTerminated }
        if message.hasPrefix("Connection terminated") { return .terminated }
        return nil
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
