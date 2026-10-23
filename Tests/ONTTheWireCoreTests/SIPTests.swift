import Foundation
import Testing
@testable import ONTTheWireCore

struct SIPTemplateTests {
    /// The WiC template as exported by 3CX (routing parameters trimmed).
    static let wic = """
    <?xml version="1.0"?>
    <doc xmlns:tcx="http://www.3cx.com">
    <header>
        <type>gateway-template</type>
        <version>150000</version>
        <name>WiC</name>
        <description>IT</description>
    </header>
    <data>
       <device>
          <type>provider</type>
          <manufacturer>WiC</manufacturer>
          <field name="Name">WiC</field>
          <field name="RegistrarHost">voip.mywic.it</field>                        <!-- Registrar & Proxy -->
          <field name="RegistrarPort">5060</field>
          <field name="ProxyHost"></field>
          <field name="ProxyPort">5060</field>
          <field name="LineAuthenticationPassword" status="readonly"></field>
          <field name="TimeBetweenRegistration">300</field>
          <field name="RequireAuthFor">4</field>
          <field name="3wayauthenticationid" status="readonly"></field>
          <field name="IPRestriction">IPV4</field>
          <field name="TransportRestriction">UDP</field>
        <codecs>
          <codec rfcname="pcma"/>
          <codec rfcname="g729"/>
        </codecs>
          <field name="ParameterIn" custom="" parameter="ToUserPart">$CalledNum</field>
          <field name="ParameterIn" custom="" parameter="FromDisplayName">$CallerName</field>
       </device>
    </data>
    </doc>
    """

    @Test func parsesWiC() throws {
        let template = try SIPTemplate.parse(Data(Self.wic.utf8), fileName: "WiC.xml")
        #expect(template.name == "WiC")
        #expect(template.registrarHost == "voip.mywic.it")
        #expect(template.registrarPort == 5060)
        #expect(template.proxyHost == nil)
        #expect(template.transport == "UDP")
        #expect(template.supportsUDP)
        #expect(template.registrationExpiry == 300)
        #expect(template.separateAuthID)
        #expect(template.codecs == ["pcma", "g729"])
        #expect(RTPCodec.preferred(by: template.codecs) == [.pcma, .pcmu])
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: SIPTemplateError.notGatewayTemplate) {
            try SIPTemplate.parse(Data("<doc><header><type>phone</type></header></doc>".utf8), fileName: "x")
        }
        let gateway = Self.wic.replacingOccurrences(of: "<type>provider</type>", with: "<type>gateway</type>")
        #expect(throws: SIPTemplateError.notProvider("gateway")) {
            try SIPTemplate.parse(Data(gateway.utf8), fileName: "x")
        }
        #expect(throws: SIPTemplateError.unreadable) {
            try SIPTemplate.parse(Data("not xml".utf8), fileName: "x")
        }
    }

    @MainActor
    @Test func storeKeepsImportedCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("export.xml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.wic.utf8).write(to: source)

        let store = SIPTemplateStore(directory: directory.appendingPathComponent("store"))
        let imported = try store.importTemplate(from: source)
        #expect(imported.fileName == "WiC.xml")
        #expect(store.templates.map(\.name) == ["WiC"])
        // Same name: replaced, not duplicated.
        try store.importTemplate(from: source)
        #expect(store.templates.count == 1)
        #expect(SIPTemplateStore(directory: directory.appendingPathComponent("store")).templates.count == 1)
        store.remove(imported)
        #expect(store.templates.isEmpty)
    }
}

struct SIPMessageTests {
    @Test func parsesResponse() throws {
        let text = "SIP/2.0 401 Unauthorized\r\n"
            + "v: SIP/2.0/UDP 192.168.1.10:5060;branch=z9hG4bKabc;rport=40312;received=93.40.1.2\r\n"
            + "From: <sip:0612345678@voip.mywic.it>;tag=f1\r\n"
            + "To: <sip:0612345678@voip.mywic.it>;tag=t9\r\n"
            + "Call-ID: xyz@192.168.1.10\r\n"
            + "CSeq: 1 REGISTER\r\n"
            + "WWW-Authenticate: Digest realm=\"voip.mywic.it\", nonce=\"abc,123\", qop=\"auth\", algorithm=MD5\r\n"
            + "Content-Length: 0\r\n\r\n"
        let message = try #require(SIPMessage.parse(Data(text.utf8)))
        #expect(message.statusCode == 401)
        #expect(message.topBranch == "z9hG4bKabc")
        #expect(message.cseq?.number == 1)
        #expect(message.cseq?.method == "REGISTER")
        let via = try #require(message.headerValues("Via").first)
        #expect(SIPHeader.parameter("received", in: via) == "93.40.1.2")
        #expect(SIPHeader.parameter("rport", in: via) == "40312")
        #expect(message.header("To").flatMap { SIPHeader.parameter("tag", in: $0) } == "t9")

        let challenge = try #require(message.header("WWW-Authenticate").flatMap(DigestChallenge.parse))
        #expect(challenge.realm == "voip.mywic.it")
        #expect(challenge.nonce == "abc,123")
        #expect(challenge.qop == ["auth"])
    }

    @Test func roundTripsRequestWithBody() throws {
        let body = Data("v=0\r\n".utf8)
        let request = SIPMessage(.request(method: "INVITE", uri: "sip:100@example.com"), headers: [
            ("Via", "SIP/2.0/UDP 10.0.0.1:5060;branch=z9hG4bK1"), ("Call-ID", "a"), ("CSeq", "2 INVITE"),
        ], body: body)
        let parsed = try #require(SIPMessage.parse(request.serialized()))
        #expect(parsed.method == "INVITE")
        #expect(parsed.requestURI == "sip:100@example.com")
        #expect(parsed.header("Content-Length") == "5")
        #expect(parsed.body == body)
    }

    @Test func splitsListsAndNameAddr() {
        let list = SIPHeader.splitList("<sip:p1.example.com;lr>, \"Doe, John\" <sip:a@b>, <sip:p2;lr>")
        #expect(list.count == 3)
        #expect(SIPHeader.uri(in: list[1]) == "sip:a@b")
        #expect(SIPHeader.displayName(in: list[1]) == "Doe, John")
        #expect(SIPHeader.user(in: "sip:0612345678@voip.mywic.it:5060") == "0612345678")
        #expect(SIPHeader.parameter("tag", in: "<sip:a@b;transport=udp>") == nil)
    }

    @Test func traceHidesDigestResponse() {
        let request = SIPMessage(.request(method: "REGISTER", uri: "sip:x"), headers: [
            ("Authorization", "Digest username=\"u\", response=\"0123abcd\", nonce=\"n\""),
        ])
        #expect(!request.redactedText.contains("0123abcd"))
        #expect(request.redactedText.contains("username=\"u\""))
    }
}

struct SIPDigestTests {
    /// RFC 2617 §3.5.
    @Test func matchesRFC2617Example() {
        let challenge = DigestChallenge(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
                                        opaque: "5ccc069c403ebaf9f0171e9517f40e41", algorithm: "MD5", qop: ["auth"], stale: false)
        let header = challenge.authorization(method: "GET", uri: "/dir/index.html", username: "Mufasa",
                                             password: "Circle Of Life", cnonce: "0a4f113b", nonceCount: 1)
        #expect(header.contains("response=\"6629fae49393a05397450978507c4ef1\""))
        #expect(header.contains("nc=00000001"))
        #expect(header.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""))
    }

    @Test func withoutQop() {
        let challenge = DigestChallenge(realm: "r", nonce: "n", opaque: nil, algorithm: "MD5", qop: [], stale: false)
        let header = challenge.authorization(method: "REGISTER", uri: "sip:d", username: "u", password: "p")
        let ha1 = DigestChallenge.md5("u:r:p")
        let ha2 = DigestChallenge.md5("REGISTER:sip:d")
        #expect(header.contains("response=\"\(DigestChallenge.md5("\(ha1):n:\(ha2)"))\""))
        #expect(!header.contains("qop"))
    }
}

struct SDPTests {
    @Test func describesAndParses() throws {
        let text = SDPMedia.describe(address: "93.40.1.2", port: 40000, codecs: [.pcma, .pcmu], sessionID: 7)
        let media = try #require(SDPMedia.parse(text))
        #expect(media.address == "93.40.1.2")
        #expect(media.port == 40000)
        #expect(media.payloadTypes == [8, 0, 101])
    }

    @Test func picksAnswerersCodecAndMediaAddress() throws {
        let answer = "v=0\r\no=- 1 1 IN IP4 10.1.1.1\r\ns=-\r\nc=IN IP4 10.1.1.1\r\nt=0 0\r\n"
            + "m=audio 31000 RTP/AVP 0 8 101\r\nc=IN IP4 185.1.2.3\r\na=rtpmap:0 PCMU/8000\r\n"
        let media = try #require(SDPMedia.parse(answer))
        #expect(media.address == "185.1.2.3")
        #expect(media.firstCommonCodec(with: [.pcma, .pcmu]) == .pcmu)
        let g729Only = "v=0\r\nc=IN IP4 1.2.3.4\r\nm=audio 1 RTP/AVP 18\r\n"
        #expect(SDPMedia.parse(g729Only)?.firstCommonCodec(with: [.pcma, .pcmu]) == nil)
    }
}

struct G711Tests {
    @Test func silenceAndRoundTrip() {
        #expect(G711.aLaw(0) == 0xD5)
        #expect(G711.uLaw(0) == 0xFF)
        for sample: Int16 in [-32768, -8000, -1000, -10, 0, 10, 1000, 8000, 32767] {
            for codec in RTPCodec.allCases {
                let decoded = Int(G711.decode(G711.encode(sample, codec), codec))
                // Logarithmic quantization: error within ~1/16 of the magnitude.
                #expect(abs(decoded - Int(sample)) <= max(abs(Int(sample)) / 16, 16), "\(codec) \(sample) → \(decoded)")
            }
        }
    }

    @Test func parsesRTPPayload() throws {
        var packet: [UInt8] = [0x80, 0x08, 0, 1, 0, 0, 0, 160, 1, 2, 3, 4]
        packet += [0xD5, 0xD5]
        let (pt, payload) = try #require(RTPStream.parse(Data(packet)))
        #expect(pt == 8)
        #expect(payload.count == 2)
    }

    @Test func describesCallFailures() {
        #expect(SIPPhone.describeCallFailure(code: 486, reason: "Busy Here") == "Numero occupato (486).")
        #expect(SIPPhone.describeCallFailure(code: 499, reason: "Strange") == "Chiamata non riuscita: 499 Strange.")
    }
}
