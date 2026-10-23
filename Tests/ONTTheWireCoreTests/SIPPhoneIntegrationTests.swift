import Foundation
import os
import Testing
@testable import ONTTheWireCore

/// End-to-end exchange with a fake provider on the loopback interface:
/// digest-challenged registration, an outgoing call and an incoming one, each
/// with RTP in both directions.
/// Printed on timeout, to see where the exchange stopped.
@MainActor private var lastPhone: SIPPhone?

@MainActor
@Suite(.serialized)
struct SIPPhoneIntegrationTests {
    @Test func registersCallsAndAnswers() async throws {
        let provider = try FakeProvider()
        let phone = SIPPhone(templates: SIPTemplateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)))
        phone.selectedTemplateID = nil
        phone.number = "0612345678"
        phone.authID = "auth-0612"
        phone.password = "segreta"
        phone.server = "127.0.0.1"
        phone.portText = String(provider.sipPort)
        #expect(phone.problems.isEmpty)
        lastPhone = phone

        // Registration: 401 challenge, then 200.
        await phone.register()
        try await waitUntil { phone.registration.isRegistered }
        #expect(phone.registration == .registered(expires: 120))
        #expect(provider.registeredAuthUser == "auth-0612")
        #expect(provider.digestValid)
        #expect(!phone.traceText.contains("segreta"))

        // Outgoing: 407 challenge, ringing, answer, echo audio, our BYE.
        phone.destination = "3331234567"
        phone.startOutgoingCall()
        try await waitUntil { if case .active = phone.call { return true }; return false }
        #expect(provider.invitedNumber == "3331234567")
        try await waitUntil { (phone.audio?.received ?? 0) >= 10 && provider.rtpReceived >= 10 }
        phone.hangUp()
        try await waitUntil { phone.call.isIdle }
        #expect(provider.byeReceived)
        let outgoing = try #require(phone.report)
        #expect(outgoing.answered)
        #expect(outgoing.success)
        #expect(outgoing.codec == RTPCodec.pcma.displayName)

        // Incoming: the provider calls the registered contact, the phone
        // answers by itself, the caller hangs up.
        phone.waitForIncomingCall()
        provider.callPhone()
        try await waitUntil(timeout: 8) { if case .active(.incoming, _, _) = phone.call { return true }; return false }
        try await waitUntil { provider.answered && (phone.audio?.received ?? 0) >= 10 }
        provider.hangUpIncoming()
        try await waitUntil { phone.call.isIdle }
        let incoming = try #require(phone.report)
        #expect(incoming.direction == .incoming)
        #expect(incoming.answered)
        #expect(incoming.packetsReceived >= 10)
        #expect(incoming.outcome.contains("riagganciato"))

        await phone.unregister()
        #expect(phone.registration == .idle)
        #expect(provider.unregistered)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out")
                print(lastPhone?.log.plainText ?? "", lastPhone?.traceText ?? "")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A tiny registrar/proxy and media endpoint on 127.0.0.1.
private final class FakeProvider: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake.provider")
    private var sip: UDPSocket!
    private var rtp: UDPSocket!
    private let state = OSAllocatedUnfairLock(initialState: Observed())

    struct Observed {
        var registeredAuthUser: String?
        var digestValid = false
        var unregistered = false
        var invitedNumber: String?
        var byeReceived = false
        var answered = false
        var rtpReceived = 0
        var contact: UDPEndpoint?
        var incomingOK: SIPMessage?
        var phoneRTP: UDPEndpoint?
    }

    var sipPort: UInt16 { sip.localPort }
    var registeredAuthUser: String? { state.withLock { $0.registeredAuthUser } }
    var digestValid: Bool { state.withLock { $0.digestValid } }
    var unregistered: Bool { state.withLock { $0.unregistered } }
    var invitedNumber: String? { state.withLock { $0.invitedNumber } }
    var byeReceived: Bool { state.withLock { $0.byeReceived } }
    var answered: Bool { state.withLock { $0.answered } }
    var rtpReceived: Int { state.withLock { $0.rtpReceived } }

    private let nonce = "fakenonce42"
    private let incomingCallID = "incoming-1@127.0.0.1"

    init() throws {
        var onSIP: ((Data, UDPEndpoint) -> Void)?
        var onRTP: ((Data, UDPEndpoint) -> Void)?
        sip = try UDPSocket(interface: nil, preferredPorts: [], queue: queue) { onSIP?($0, $1) }
        rtp = try UDPSocket(interface: nil, preferredPorts: [], queue: queue) { onRTP?($0, $1) }
        onSIP = { [weak self] data, from in self?.handleSIP(data, from: from) }
        onRTP = { [weak self] data, from in
            guard let self else { return }
            self.state.withLock { $0.rtpReceived += 1 }
            // Echo back so the phone receives audio too.
            self.rtp.send(data, to: from)
        }
    }

    private func handleSIP(_ data: Data, from: UDPEndpoint) {
        guard let message = SIPMessage.parse(data) else { return }
        if let code = message.statusCode {
            handleResponse(code, message, from: from)
            return
        }
        switch message.method {
        case "REGISTER":
            guard let auth = message.header("Authorization") else {
                reply(message, 401, "Unauthorized", from: from,
                      extra: [("WWW-Authenticate", "Digest realm=\"fake\", nonce=\"\(nonce)\", qop=\"auth\", algorithm=MD5")])
                return
            }
            checkDigest(auth, method: "REGISTER")
            let expires = message.header("Expires") ?? "0"
            let contact = message.header("Contact") ?? ""
            state.withLock { observed in
                if expires == "0" { observed.unregistered = true }
                let uri = SIPHeader.uri(in: contact)
                if let hostPort = uri.split(separator: "@").last {
                    let parts = hostPort.split(separator: ":")
                    if parts.count == 2, let port = Int(parts[1]) {
                        observed.contact = UDPEndpoint(address: String(parts[0]), port: port)
                    }
                }
            }
            reply(message, 200, "OK", from: from, extra: [("Contact", "\(contact);expires=\(expires == "0" ? "0" : "120")")])
        case "INVITE":
            guard message.header("Proxy-Authorization") != nil else {
                reply(message, 407, "Proxy Authentication Required", from: from, toTag: "p1",
                      extra: [("Proxy-Authenticate", "Digest realm=\"fake\", nonce=\"\(nonce)\"")])
                return
            }
            state.withLock { $0.invitedNumber = message.requestURI.flatMap(SIPHeader.user(in:)) }
            reply(message, 100, "Trying", from: from)
            reply(message, 180, "Ringing", from: from, toTag: "callee")
            let sdp = SDPMedia.describe(address: "127.0.0.1", port: Int(rtp.localPort), codecs: [.pcma], sessionID: 9)
            reply(message, 200, "OK", from: from, toTag: "callee",
                  extra: [("Contact", "<sip:3331234567@127.0.0.1:\(sip.localPort)>"), ("Content-Type", "application/sdp")],
                  body: Data(sdp.utf8))
        case "BYE":
            state.withLock { $0.byeReceived = true }
            reply(message, 200, "OK", from: from)
        default:
            break
        }
    }

    private func handleResponse(_ code: Int, _ message: SIPMessage, from: UDPEndpoint) {
        guard message.header("Call-ID") == incomingCallID, message.cseq?.method == "INVITE", code == 200 else { return }
        let media = SDPMedia.parse(message.bodyText)
        state.withLock {
            $0.answered = true
            $0.incomingOK = message
            $0.phoneRTP = media.flatMap { UDPEndpoint(address: $0.address, port: $0.port) }
        }
        var ack = SIPMessage(.request(method: "ACK", uri: "sip:0612345678@127.0.0.1"), headers: [
            ("Via", "SIP/2.0/UDP 127.0.0.1:\(sip.localPort);branch=z9hG4bKack1"),
            ("From", message.header("From") ?? ""), ("To", message.header("To") ?? ""),
            ("Call-ID", incomingCallID), ("CSeq", "1 ACK"),
        ])
        ack.removeHeader("Content-Type")
        sip.send(ack.serialized(), to: from)
        // Talk to the phone so it has audio to echo.
        if let target = state.withLock({ $0.phoneRTP }) {
            for i in 0..<30 {
                queue.asyncAfter(deadline: .now() + .milliseconds(20 * i)) {
                    var packet: [UInt8] = [0x80, 0x08, 0, UInt8(i), 0, 0, 0, 0, 9, 9, 9, 9]
                    packet += (0..<160).map { UInt8(truncatingIfNeeded: 0x55 ^ ($0 % 16)) }
                    self.rtp.send(Data(packet), to: target)
                }
            }
        }
    }

    func callPhone() {
        queue.async {
            guard let contact = self.state.withLock({ $0.contact }) else { return }
            let sdp = SDPMedia.describe(address: "127.0.0.1", port: Int(self.rtp.localPort), codecs: [.pcma, .pcmu], sessionID: 5)
            let invite = SIPMessage(.request(method: "INVITE", uri: "sip:0612345678@\(contact)"), headers: [
                ("Via", "SIP/2.0/UDP 127.0.0.1:\(self.sip.localPort);branch=z9hG4bKinv1"),
                ("Max-Forwards", "70"),
                ("From", "\"Mario\" <sip:3339998877@fake>;tag=caller"),
                ("To", "<sip:0612345678@fake>"),
                ("Call-ID", self.incomingCallID), ("CSeq", "1 INVITE"),
                ("Contact", "<sip:3339998877@127.0.0.1:\(self.sip.localPort)>"),
                ("Content-Type", "application/sdp"),
            ], body: Data(sdp.utf8))
            self.sip.send(invite.serialized(), to: contact)
        }
    }

    func hangUpIncoming() {
        queue.async {
            guard let contact = self.state.withLock({ $0.contact }), let ok = self.state.withLock({ $0.incomingOK }) else { return }
            let bye = SIPMessage(.request(method: "BYE", uri: "sip:0612345678@\(contact)"), headers: [
                ("Via", "SIP/2.0/UDP 127.0.0.1:\(self.sip.localPort);branch=z9hG4bKbye1"),
                ("From", ok.header("From") ?? ""), ("To", ok.header("To") ?? ""),
                ("Call-ID", self.incomingCallID), ("CSeq", "2 BYE"),
            ])
            self.sip.send(bye.serialized(), to: contact)
        }
    }

    private func checkDigest(_ header: String, method: String) {
        func field(_ name: String) -> String? {
            header.range(of: "\(name)=\"([^\"]*)\"", options: .regularExpression).map {
                String(header[$0]).components(separatedBy: "\"")[1]
            }
        }
        guard let user = field("username"), let uri = field("uri"), let cnonce = field("cnonce"),
              let response = field("response") else { return }
        let ha1 = DigestChallenge.md5("\(user):fake:segreta")
        let ha2 = DigestChallenge.md5("\(method):\(uri)")
        let expected = DigestChallenge.md5("\(ha1):\(nonce):00000001:\(cnonce):auth:\(ha2)")
        state.withLock {
            $0.registeredAuthUser = user
            $0.digestValid = response == expected
        }
    }

    private func reply(_ request: SIPMessage, _ code: Int, _ reason: String, from: UDPEndpoint, toTag: String? = nil,
                       extra: [(String, String)] = [], body: Data = Data()) {
        var to = request.header("To") ?? ""
        if let toTag, SIPHeader.parameter("tag", in: to) == nil { to += ";tag=\(toTag)" }
        var headers: [(String, String)] = request.headerValues("Via").map { ("Via", $0) }
        headers += [("From", request.header("From") ?? ""), ("To", to),
                    ("Call-ID", request.header("Call-ID") ?? ""), ("CSeq", request.header("CSeq") ?? "")]
        headers += extra
        sip.send(SIPMessage(.response(code: code, reason: reason), headers: headers, body: body).serialized(), to: from)
    }
}
