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

    @Test func pppAuthenticationFailure() {
        let lines = [
            "11:20:44 pppoe-relay: LCP aperto: MRU del server 1492, autenticazione CHAP",
            "11:20:44 pppoe-relay: STATUS auth CHAP",
            "11:20:47 pppoe-relay: STATUS auth-failed ",
            "11:20:47 pppoe-relay: STATUS padt inviato, sessione 19247 chiusa",
        ]
        #expect(lines.compactMap(SessionLogParser.parseRelayLine) == [
            .authenticating(method: "CHAP"), .authenticationFailed,
        ])
    }

    @Test func pppAddresses() {
        let lines = [
            "12:00:00 pppoe-relay: STATUS auth-ok",
            "12:00:01 pppoe-relay: STATUS interface utun7 mtu=1492",
            "12:00:01 pppoe-relay: STATUS local 79.1.2.3",
            "12:00:01 pppoe-relay: STATUS remote 192.168.100.1",
            "12:00:01 pppoe-relay: STATUS dns 85.37.17.12",
            "12:00:01 pppoe-relay: STATUS dns 85.38.28.84",
            "12:00:01 pppoe-relay: STATUS up utun7 local=79.1.2.3 remote=192.168.100.1 dns=85.37.17.12,85.38.28.84",
            "12:30:00 pppoe-relay: STATUS echo-timeout nessuna risposta a 4 LCP echo",
            "12:30:00 pppoe-relay: STATUS lcp-terminated dal server",
            "12:30:00 pppoe-relay: STATUS stats ricevuti 120, inviati 80; invio: coda piena 3 volte, scartati 0",
        ]
        #expect(lines.compactMap(SessionLogParser.parseRelayLine) == [
            .authenticated, .linkInterface("utun7"), .localAddress("79.1.2.3"), .remoteAddress("192.168.100.1"),
            .dnsServer("85.37.17.12"), .dnsServer("85.38.28.84"), .echoTimeout, .peerTerminated,
            .statistics("ricevuti 120, inviati 80; invio: coda piena 3 volte, scartati 0"),
        ])
    }

    @Test func lineBufferKeepsPartialLines() {
        var buffer = LineBuffer()
        #expect(buffer.append("uno\ndu") == ["uno"])
        #expect(buffer.append("e\ntre\n") == ["due", "tre"])
        #expect(buffer.append("") == [])
    }

    @Test func secretQuoting() {
        #expect(PrivilegedSession.secretQuoted(#"pa"ss\word"#) == #""pa\"ss\\word""#)
    }

    @Test func exitCodes() {
        #expect(ConnectionController.describe(exitStatus: 19, wasConnected: false).contains("username e password"))
        #expect(ConnectionController.describe(exitStatus: 5, wasConnected: true) == "Connessione interrotta.")
    }
}
