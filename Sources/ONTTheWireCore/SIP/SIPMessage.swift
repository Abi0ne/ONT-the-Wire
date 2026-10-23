import Foundation

/// A SIP request or response (RFC 3261), as text headers plus a body.
struct SIPMessage: Sendable {
    enum StartLine: Equatable, Sendable {
        case request(method: String, uri: String)
        case response(code: Int, reason: String)
    }

    var start: StartLine
    /// Headers in order, with the names as written (compact forms included).
    var headers: [(name: String, value: String)]
    var body: Data

    init(_ start: StartLine, headers: [(String, String)] = [], body: Data = Data()) {
        self.start = start
        self.headers = headers.map { (name: $0.0, value: $0.1) }
        self.body = body
    }

    var method: String? {
        if case .request(let method, _) = start { return method }
        return nil
    }

    var requestURI: String? {
        if case .request(_, let uri) = start { return uri }
        return nil
    }

    var statusCode: Int? {
        if case .response(let code, _) = start { return code }
        return nil
    }

    var summary: String {
        switch start {
        case .request(let method, let uri): "\(method) \(uri)"
        case .response(let code, let reason): "\(code) \(reason)"
        }
    }

    // MARK: Headers

    private static let compactForms: [String: String] = [
        "i": "call-id", "m": "contact", "e": "content-encoding", "l": "content-length",
        "c": "content-type", "f": "from", "s": "subject", "k": "supported", "t": "to", "v": "via",
    ]

    private static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        return compactForms[lower] ?? lower
    }

    /// The first value of a header, case-insensitive, compact forms included.
    func header(_ name: String) -> String? {
        let key = Self.canonical(name)
        return headers.first { Self.canonical($0.name) == key }?.value
    }

    /// Every value of a header, splitting comma-separated lists
    /// (Via, Route, Record-Route, Contact).
    func headerValues(_ name: String) -> [String] {
        let key = Self.canonical(name)
        return headers.filter { Self.canonical($0.name) == key }.flatMap { SIPHeader.splitList($0.value) }
    }

    /// Every value of a header as written, without splitting on commas
    /// (for WWW-Authenticate and other headers whose values contain commas).
    func headerFields(_ name: String) -> [String] {
        let key = Self.canonical(name)
        return headers.filter { Self.canonical($0.name) == key }.map(\.value)
    }

    mutating func addHeader(_ name: String, _ value: String) {
        headers.append((name: name, value: value))
    }

    mutating func removeHeader(_ name: String) {
        let key = Self.canonical(name)
        headers.removeAll { Self.canonical($0.name) == key }
    }

    var cseq: (number: Int, method: String)? {
        guard let parts = header("CSeq")?.split(separator: " ", omittingEmptySubsequences: true),
              parts.count == 2, let number = Int(parts[0]) else { return nil }
        return (number, String(parts[1]).uppercased())
    }

    /// The branch of the topmost Via.
    var topBranch: String? {
        headerValues("Via").first.flatMap { SIPHeader.parameter("branch", in: $0) }
    }

    var hasSDP: Bool {
        !body.isEmpty && (header("Content-Type")?.lowercased().hasPrefix("application/sdp") ?? false)
    }

    var bodyText: String { String(decoding: body, as: UTF8.self) }

    // MARK: Wire format

    static func parse(_ data: Data) -> SIPMessage? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst()

        let start: StartLine
        if first.hasPrefix("SIP/2.0 ") {
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            start = .response(code: code, reason: parts.count > 2 ? String(parts[2]) : "")
        } else {
            let parts = first.split(separator: " ")
            guard parts.count == 3, parts[2] == "SIP/2.0" else { return nil }
            start = .request(method: String(parts[0]).uppercased(), uri: String(parts[1]))
        }

        var headers: [(String, String)] = []
        for line in lines {
            if let firstChar = line.first, firstChar == " " || firstChar == "\t", !headers.isEmpty {
                // Folded continuation line.
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        var message = SIPMessage(start, headers: headers)
        var body = Data(data[separator.upperBound...])
        if let length = message.header("Content-Length").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           length < body.count {
            body = body.prefix(length)
        }
        message.body = body
        return message
    }

    func serialized() -> Data {
        var text: String
        switch start {
        case .request(let method, let uri): text = "\(method) \(uri) SIP/2.0\r\n"
        case .response(let code, let reason): text = "SIP/2.0 \(code) \(reason)\r\n"
        }
        for header in headers where Self.canonical(header.name) != "content-length" {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        return Data(text.utf8) + body
    }

    /// The message as text for the SIP trace, with digest responses hidden.
    var redactedText: String {
        var copy = self
        for (index, header) in copy.headers.enumerated()
        where ["authorization", "proxy-authorization"].contains(header.name.lowercased()) {
            copy.headers[index].value = header.value.replacingOccurrences(
                of: #"response="[^"]*""#, with: #"response="…""#, options: .regularExpression)
        }
        return String(decoding: copy.serialized(), as: UTF8.self)
    }
}

/// Helpers for header values such as `"Name" <sip:100@host>;tag=abc`.
enum SIPHeader {
    /// Splits a comma-separated header list, ignoring commas inside quotes
    /// and angle brackets.
    static func splitList(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for char in value {
            switch char {
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            case "," where !inQuotes && !inAngle:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(char)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// The URI of a name-addr (`<sip:…>`) or addr-spec (`sip:…;params`).
    static func uri(in value: String) -> String {
        if let open = value.firstIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
            return String(value[value.index(after: open)..<close])
        }
        let spec = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        return spec.trimmingCharacters(in: .whitespaces)
    }

    /// A header parameter (after the URI's closing `>`, if any), e.g. `tag`.
    /// Flag parameters without a value return "".
    static func parameter(_ name: String, in value: String) -> String? {
        let tail: Substring
        if let close = value.lastIndex(of: ">") {
            tail = value[value.index(after: close)...]
        } else if let semicolon = value.firstIndex(of: ";") {
            tail = value[semicolon...]
        } else {
            return nil
        }
        for part in tail.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard let key = pair.first?.trimmingCharacters(in: .whitespaces), key.lowercased() == name.lowercased() else { continue }
            return pair.count > 1 ? pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"")) : ""
        }
        return nil
    }

    /// The user part of a SIP URI, e.g. "0612345678" for `sip:0612345678@host`.
    static func user(in uri: String) -> String? {
        var rest = Substring(uri)
        if let colon = rest.firstIndex(of: ":") { rest = rest[rest.index(after: colon)...] }
        guard let at = rest.firstIndex(of: "@") else { return nil }
        return String(rest[..<at])
    }

    /// The display name of a name-addr, without quotes.
    static func displayName(in value: String) -> String? {
        guard let open = value.firstIndex(of: "<") else { return nil }
        let name = value[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? nil : name
    }

    static func randomToken(_ bytes: Int = 8) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
