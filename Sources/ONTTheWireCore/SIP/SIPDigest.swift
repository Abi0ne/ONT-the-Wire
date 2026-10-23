import CryptoKit
import Foundation

/// HTTP digest authentication as used by SIP (RFC 2617 / RFC 8760): the
/// challenge of a 401/407 and the matching Authorization header.
struct DigestChallenge: Equatable, Sendable {
    var realm: String
    var nonce: String
    var opaque: String?
    var algorithm: String
    var qop: [String]
    var stale: Bool

    /// Parses `Digest realm="…", nonce="…", qop="auth", algorithm=MD5`.
    static func parse(_ header: String) -> DigestChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }
        var params: [String: String] = [:]
        for part in SIPHeader.splitList(String(trimmed.dropFirst("digest".count))) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            params[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        return DigestChallenge(
            realm: realm, nonce: nonce, opaque: params["opaque"],
            algorithm: params["algorithm"]?.uppercased() ?? "MD5",
            qop: params["qop"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } } ?? [],
            stale: params["stale"]?.lowercased() == "true")
    }

    var isSupported: Bool {
        ["MD5", "MD5-SESS", "SHA-256", "SHA-256-SESS"].contains(algorithm)
    }

    /// The value for an Authorization / Proxy-Authorization header.
    func authorization(method: String, uri: String, username: String, password: String,
                       cnonce: String = SIPHeader.randomToken(), nonceCount: Int = 1) -> String {
        let hash: (String) -> String = algorithm.hasPrefix("SHA-256") ? Self.sha256 : Self.md5
        var ha1 = hash("\(username):\(realm):\(password)")
        if algorithm.hasSuffix("-SESS") { ha1 = hash("\(ha1):\(nonce):\(cnonce)") }
        let ha2 = hash("\(method):\(uri)")
        let nc = String(format: "%08x", nonceCount)
        let useQop = qop.contains("auth")
        let response = useQop
            ? hash("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            : hash("\(ha1):\(nonce):\(ha2)")

        var fields = [
            "username=\"\(username)\"", "realm=\"\(realm)\"", "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"", "response=\"\(response)\"",
            "algorithm=\(algorithm == "MD5-SESS" ? "MD5-sess" : algorithm)",
        ]
        if useQop { fields += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""] }
        if let opaque { fields.append("opaque=\"\(opaque)\"") }
        return "Digest " + fields.joined(separator: ", ")
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
