import Foundation

/// Audio codecs the test calls can send: G.711 only, which every SIP trunk
/// accepts. G.729 is patent-free now but needs a real encoder.
enum RTPCodec: Int, CaseIterable, Sendable {
    case pcmu = 0
    case pcma = 8

    var payloadType: Int { rawValue }

    var rtpmap: String {
        switch self {
        case .pcmu: "PCMU/8000"
        case .pcma: "PCMA/8000"
        }
    }

    var displayName: String {
        switch self {
        case .pcmu: "G.711 µ-law"
        case .pcma: "G.711 A-law"
        }
    }

    /// Our offer in the template's order (3CX names "pcma", "pcmu"), then
    /// the other G.711 variant; A-law first by default, as in Europe.
    static func preferred(by templateCodecs: [String]) -> [RTPCodec] {
        var result: [RTPCodec] = templateCodecs.compactMap {
            switch $0.lowercased() {
            case "pcma", "g711a": .pcma
            case "pcmu", "g711u": .pcmu
            default: nil
            }
        }
        for codec in [RTPCodec.pcma, .pcmu] where !result.contains(codec) { result.append(codec) }
        return result
    }
}

/// The audio stream described by an SDP body (RFC 4566).
struct SDPMedia: Equatable, Sendable {
    static let telephoneEvent = 101

    var address: String
    var port: Int
    var payloadTypes: [Int]

    /// Our session description: one audio stream, G.711 plus DTMF events.
    static func describe(address: String, port: Int, codecs: [RTPCodec], sessionID: UInt64, version: UInt64 = 1) -> String {
        let payloads = codecs.map(\.payloadType) + [telephoneEvent]
        var lines = [
            "v=0",
            "o=ONTTheWire \(sessionID) \(version) IN IP4 \(address)",
            "s=ONT The Wire",
            "c=IN IP4 \(address)",
            "t=0 0",
            "m=audio \(port) RTP/AVP " + payloads.map(String.init).joined(separator: " "),
        ]
        lines += codecs.map { "a=rtpmap:\($0.payloadType) \($0.rtpmap)" }
        lines += ["a=rtpmap:\(telephoneEvent) telephone-event/8000", "a=fmtp:\(telephoneEvent) 0-15", "a=ptime:20", "a=sendrecv"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The first audio stream, with the media-level `c=` taking precedence
    /// over the session-level one.
    static func parse(_ text: String) -> SDPMedia? {
        var sessionAddress: String?
        var mediaAddress: String?
        var port: Int?
        var payloads: [Int] = []
        var inAudio = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if port != nil { break }
                let parts = line.dropFirst(2).split(separator: " ")
                inAudio = parts.first == "audio"
                if inAudio, parts.count >= 4, let p = Int(parts[1]) {
                    port = p
                    payloads = parts.dropFirst(3).compactMap { Int($0) }
                }
            } else if line.hasPrefix("c=") {
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 3 else { continue }
                let address = String(parts[2].split(separator: "/").first ?? parts[2])
                if inAudio { mediaAddress = address } else if port == nil { sessionAddress = address }
            }
        }
        guard let port, let address = mediaAddress ?? sessionAddress else { return nil }
        return SDPMedia(address: address, port: port, payloadTypes: payloads)
    }

    /// The first codec of `ours` the remote side lists, in the remote's order
    /// (that is the codec the answerer has chosen).
    func firstCommonCodec(with ours: [RTPCodec]) -> RTPCodec? {
        payloadTypes.lazy.compactMap { pt in ours.first { $0.payloadType == pt } }.first
    }

    /// A port of 0 or address 0.0.0.0 means the stream is disabled/on hold.
    var isActive: Bool { port != 0 && address != "0.0.0.0" }
}
