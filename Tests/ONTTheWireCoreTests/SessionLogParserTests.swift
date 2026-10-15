import Testing
@testable import ONTTheWireCore

/// Lines captured from a real session against a TIM concentrator (2026-10-15).
struct SessionLogParserTests {
    @Test func relayDiscoveryLines() {
        #expect(SessionLogParser.parseRelayLine("11:20:43 pppoe-relay: STATUS discovery en7 mac=c4:d6:d3:ae:e5:58 vlan=835 pcp=0")
            == .discoveryStarted(interface: "en7", mac: "c4:d6:d3:ae:e5:58", vlan: 835))
        #expect(SessionLogParser.parseRelayLine("pppoe-relay: STATUS discovery en7 mac=c4:d6:d3:ae:e5:58 untagged")
            == .discoveryStarted(interface: "en7", mac: "c4:d6:d3:ae:e5:58", vlan: nil))
        #expect(SessionLogParser.parseRelayLine(#"11:20:43 pppoe-relay: STATUS pado 02:00:5e:10:20:30 ac="BRAS-ESEMPIO-01" service="""#)
            == .serverOffered(mac: "02:00:5e:10:20:30", acName: "BRAS-ESEMPIO-01"))
        #expect(SessionLogParser.parseRelayLine("11:20:43 pppoe-relay: STATUS session 19247 ac=02:00:5e:10:20:30")
            == .sessionOpened(id: 19247, acMAC: "02:00:5e:10:20:30"))
        #expect(SessionLogParser.parseRelayLine("11:21:13 pppoe-relay: STATUS timeout nessun PADO in 30 secondi") == .noServer)
        #expect(SessionLogParser.parseRelayLine("11:20:43 pppoe-relay: PADI inviato") == nil)
    }

    @Test func padtDirection() {
        #expect(SessionLogParser.parseRelayLine("11:20:47 pppoe-relay: STATUS padt sessione chiusa dal concentratore") == .serverClosedSession)
        #expect(SessionLogParser.parseRelayLine("11:20:47 pppoe-relay: STATUS padt inviato, sessione 19247 chiusa") == nil)
    }

    @Test func pppdAuthenticationFailure() {
        let lines = [
            "Thu Oct 15 11:20:43 2026 : Using interface ppp0",
            "pppoe-relay: STATUS session 19247 ac=02:00:5e:10:20:30",
            "Thu Oct 15 11:20:46 2026 : rcvd [CHAP Challenge id=0x1 <4f77f3b6>, name = \"BRAS-ESEMPIO-01\"]",
            "Thu Oct 15 11:20:47 2026 : rcvd [CHAP Failure id=0x1 \"\"]",
            "Thu Oct 15 11:20:47 2026 : CHAP authentication failed",
            "Thu Oct 15 11:20:47 2026 : Connection terminated.",
        ]
        #expect(lines.compactMap(SessionLogParser.parsePPPDLine) == [
            .linkInterface("ppp0"), .authenticating(method: "CHAP"), .authenticationFailed, .terminated,
        ])
    }

    @Test func pppdAddresses() {
        let lines = [
            "Thu Oct 15 12:00:00 2026 : CHAP authentication succeeded",
            "Thu Oct 15 12:00:01 2026 : local  IP address 79.1.2.3",
            "Thu Oct 15 12:00:01 2026 : remote IP address 192.168.100.1",
            "Thu Oct 15 12:00:01 2026 : primary   DNS address 85.37.17.12",
            "Thu Oct 15 12:00:01 2026 : secondary DNS address 85.38.28.84",
            "Thu Oct 15 12:30:00 2026 : No response to 4 echo-requests",
        ]
        #expect(lines.compactMap(SessionLogParser.parsePPPDLine) == [
            .authenticated, .localAddress("79.1.2.3"), .remoteAddress("192.168.100.1"),
            .dnsServer("85.37.17.12"), .dnsServer("85.38.28.84"), .echoTimeout,
        ])
    }

    @Test func lineBufferKeepsPartialLines() {
        var buffer = LineBuffer()
        #expect(buffer.append("uno\ndu") == ["uno"])
        #expect(buffer.append("e\ntre\n") == ["due", "tre"])
        #expect(buffer.append("") == [])
    }

    @Test func pppdQuoting() {
        #expect(PrivilegedSession.pppdQuoted(#"pa"ss\word"#) == #""pa\"ss\\word""#)
    }

    @Test func pppdExitCodes() {
        #expect(ConnectionController.describe(pppdStatus: 19, wasConnected: false).contains("username e password"))
        #expect(ConnectionController.describe(pppdStatus: 5, wasConnected: true) == "Connessione interrotta.")
    }
}
