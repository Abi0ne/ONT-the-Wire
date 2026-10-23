import Foundation
import Observation

public enum SIPRegistrationState: Equatable, Sendable {
    case idle
    case registering
    case registered(expires: Int)
    case unregistering
    case failed(String)

    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }

    /// Fields are locked and a socket is open.
    public var isActive: Bool {
        switch self {
        case .registering, .registered, .unregistering: true
        case .idle, .failed: false
        }
    }
}

public enum SIPCallDirection: Sendable {
    case outgoing, incoming
}

public enum SIPCallState: Equatable, Sendable {
    case idle
    /// INVITE sent, no ringing yet.
    case dialing(String)
    case ringing(String)
    /// Ready to answer the next incoming call.
    case waitingIncoming
    /// An incoming call is about to be answered.
    case answering(String)
    case active(SIPCallDirection, peer: String, since: Date)
    case ending

    public var isIdle: Bool { self == .idle }
}

/// The outcome of the last test call.
public struct SIPCallReport: Equatable, Sendable {
    public var direction: SIPCallDirection
    public var peer: String
    public var success: Bool
    public var outcome: String
    public var answered: Bool
    public var duration: TimeInterval?
    public var codec: String?
    public var remoteMedia: String?
    public var packetsSent = 0
    public var packetsReceived = 0
    public var peakLevel: Double?
}

public struct SIPAudioStats: Equatable, Sendable {
    public var sent: Int
    public var received: Int
    public var peakLevel: Double?
}

/// A minimal SIP user agent over UDP (RFC 3261) for line tests: registers an
/// account, places a test call and answers one, both with an echo test (two
/// beeps, then the caller hears their own voice). Works on any network: the
/// PPPoE link, Wi-Fi or Ethernet; behind NAT it uses the public address the
/// server reports (Via received/rport) and symmetric RTP.
///
/// The password stays in memory only and never reaches the log or the SIP
/// trace (digest responses are hidden there too).
@MainActor
@Observable
public final class SIPPhone {
    public static let maxCallDuration: TimeInterval = 60
    public static let ringTimeout: TimeInterval = 60
    public static let incomingWait: TimeInterval = 180
    static let answerDelay: Duration = .seconds(2)
    static let userAgent = "ONT The Wire/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"

    public let templates: SIPTemplateStore
    public let log: LogStore

    // MARK: Account (typed by the user, never persisted)

    public var selectedTemplateID: String? {
        didSet { if selectedTemplateID != oldValue { applyTemplate() } }
    }
    public var number = ""
    public var authID = ""
    public var password = ""
    public var server = ""
    public var portText = "5060"
    /// BSD name of the network to use; nil: the Mac's primary route.
    public var networkInterface: String?
    public var destination = ""

    public private(set) var links: [SIPNetworkLink] = []
    public private(set) var registration: SIPRegistrationState = .idle
    public private(set) var call: SIPCallState = .idle
    public private(set) var audio: SIPAudioStats?
    public private(set) var report: SIPCallReport?
    /// Where the registration runs: interface and local/public address.
    public private(set) var binding: String?
    public private(set) var trace: [String] = []

    public var template: SIPTemplate? { templates.template(id: selectedTemplateID) }

    // MARK: Internal state

    @ObservationIgnored private var socket: UDPSocket?
    @ObservationIgnored private var serverEndpoint: UDPEndpoint?
    @ObservationIgnored private var account = Account(number: "", authUser: "", password: "", domain: "")
    @ObservationIgnored private var localAddress = ""
    @ObservationIgnored private var contactAddress = ""
    @ObservationIgnored private var contactPort: UInt16 = 0
    @ObservationIgnored private var behindNAT = false
    @ObservationIgnored private var codecs: [RTPCodec] = RTPCodec.preferred(by: [])
    @ObservationIgnored private var requestedExpiry = 300

    @ObservationIgnored private var regCallID = ""
    @ObservationIgnored private var regTag = ""
    @ObservationIgnored private var regCSeq = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?

    @ObservationIgnored private var transactions: [String: ClientTransaction] = [:]
    @ObservationIgnored private var current: CallContext?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?

    public init(templates: SIPTemplateStore? = nil, log: LogStore? = nil) {
        self.templates = templates ?? SIPTemplateStore()
        self.log = log ?? LogStore()
        selectedTemplateID = self.templates.templates.first?.id
        applyTemplate()
        refreshLinks()
    }

    // MARK: Derived state

    public var problems: [String] {
        var result: [String] = []
        if number.trimmingCharacters(in: .whitespaces).isEmpty { result.append("Inserisci il numero / ID dell’account.") }
        if password.isEmpty { result.append("Inserisci la password SIP.") }
        if server.trimmingCharacters(in: .whitespaces).isEmpty { result.append("Inserisci il server SIP.") }
        if port == nil { result.append("La porta deve essere un numero tra 1 e 65535.") }
        if let template, !template.supportsUDP {
            result.append("Il provider accetta solo \(template.transport): il test usa UDP.")
        }
        if let networkInterface, !links.contains(where: { $0.bsdName == networkInterface }) {
            result.append("La rete \(networkInterface) non è disponibile: scegline un’altra.")
        }
        return result
    }

    public var port: Int? {
        Int(portText).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    public var canRegister: Bool { problems.isEmpty && !registration.isActive }
    public var canCall: Bool {
        registration.isRegistered && call.isIdle && !destination.filter { !$0.isWhitespace }.isEmpty
    }

    public func refreshLinks() {
        links = SIPNetworkLink.current()
    }

    public func importTemplate(from url: URL) throws {
        let template = try templates.importTemplate(from: url)
        log.info("Template SIP “\(template.name)” importato (\(template.registrarHost):\(template.registrarPort)).")
        selectedTemplateID = template.id
        applyTemplate()
    }

    public func removeSelectedTemplate() {
        guard let template else { return }
        templates.remove(template)
        log.info("Template SIP “\(template.name)” rimosso.")
        selectedTemplateID = templates.templates.first?.id
    }

    public func clearTrace() { trace.removeAll() }

    public func clearError() {
        if case .failed = registration { registration = .idle }
    }

    public var traceText: String { trace.joined(separator: "\n") }

    private func applyTemplate() {
        guard let template else {
            codecs = RTPCodec.preferred(by: [])
            requestedExpiry = 300
            return
        }
        server = template.proxyHost ?? template.registrarHost
        portText = String(template.proxyHost != nil ? (template.proxyPort ?? 5060) : template.registrarPort)
        codecs = RTPCodec.preferred(by: template.codecs)
        requestedExpiry = template.registrationExpiry
        number = ""
        authID = ""
        password = ""
    }

    // MARK: Registration

    public func register() async {
        guard canRegister, let port else { return }
        refreshLinks()
        registration = .registering
        report = nil
        let host = server.trimmingCharacters(in: .whitespaces)
        let number = number.trimmingCharacters(in: .whitespaces)
        let authUser = authID.trimmingCharacters(in: .whitespaces)
        // The SIP domain is the registrar even when a separate proxy is used.
        let domainHost = template?.registrarHost ?? host
        let domainPort = template?.registrarPort ?? port
        account = Account(
            number: number, authUser: authUser.isEmpty ? number : authUser, password: password,
            domain: domainPort == 5060 ? domainHost : "\(domainHost):\(domainPort)")

        let endpoint: UDPEndpoint
        do {
            endpoint = try await UDPEndpoint.resolve(host, port: port)
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard registration == .registering else { return }
        guard let local = UDPEndpoint.localAddress(toward: endpoint, interface: networkInterface) else {
            fail(SIPError.noRoute(endpoint.description).localizedDescription)
            return
        }
        do {
            socket = try UDPSocket(interface: networkInterface, preferredPorts: [5060, 5062, 5064], queue: .main) { [weak self] data, from in
                MainActor.assumeIsolated { self?.receive(data, from: from) }
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        serverEndpoint = endpoint
        localAddress = local
        contactAddress = local
        contactPort = socket?.localPort ?? 0
        behindNAT = false
        regCallID = "\(SIPHeader.randomToken(12))@\(local)"
        regTag = SIPHeader.randomToken(4)

        let network = networkInterface.flatMap { name in links.first { $0.bsdName == name } }
            .map { "\($0.displayName) (\($0.bsdName))" } ?? "rete principale del Mac"
        binding = "\(network) · \(local):\(contactPort)"
        log.info("SIP: registrazione di \(number) su \(host):\(port) (\(endpoint.host)) via \(network), porta locale \(contactPort).")
        sendRegister(expires: requestedExpiry)
    }

    public func unregister() async {
        guard registration.isActive else { return }
        await endCallForShutdown()
        waitTask?.cancel()
        if case .waitingIncoming = call { call = .idle }
        refreshTask?.cancel()
        if registration.isRegistered {
            registration = .unregistering
            sendRegister(expires: 0)
            for _ in 0..<20 where registration == .unregistering {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        closeSocket()
        if registration == .unregistering || registration.isRegistered || registration == .registering {
            registration = .idle
        }
        log.info("SIP: account deregistrato.")
    }

    /// Before quitting: hang up, unregister, close.
    public func shutdown() async {
        await unregister()
    }

    public var needsShutdown: Bool { registration.isActive }

    private func sendRegister(expires: Int) {
        let domain = account.domain
        let aor = "<sip:\(account.number)@\(domain)>"
        send(method: "REGISTER", uri: "sip:\(domain)", build: { [unowned self] auth in
            regCSeq += 1
            var extra = [
                ("Contact", "<sip:\(account.number)@\(contactAddress):\(contactPort)>"),
                ("Expires", String(expires)),
                ("Allow", Self.allow),
            ]
            if let auth { extra.append(auth) }
            return makeRequest("REGISTER", uri: "sip:\(domain)", from: "\(aor);tag=\(regTag)", to: aor,
                               callID: regCallID, cseq: regCSeq, extra: extra)
        }, onFinal: { [unowned self] response in
            handleRegisterResponse(response, expires: expires)
        }, onTimeout: { [unowned self] in
            if expires == 0 {
                registration = .idle
            } else {
                fail("Il server SIP \(serverEndpoint?.description ?? server) non risponde: controlla server, porta e che la rete lasci passare UDP.")
            }
        })
    }

    private func handleRegisterResponse(_ response: SIPMessage, expires: Int) {
        guard let code = response.statusCode else { return }
        if expires == 0 {
            registration = .idle
            return
        }
        switch code {
        case 200..<300:
            if adoptPublicAddress(from: response) {
                log.info("SIP: rilevato NAT, indirizzo pubblico \(contactAddress):\(contactPort). Nuova registrazione con questo indirizzo.")
                sendRegister(expires: expires)
                return
            }
            let granted = grantedExpiry(in: response) ?? expires
            registration = .registered(expires: granted)
            log.info("SIP: registrato (\(code) \(reason(response))), scadenza \(granted) s.")
            scheduleRefresh(after: granted)
            if behindNAT { startKeepAlive() }
        case 423:
            if let minimum = response.header("Min-Expires").flatMap({ Int($0) }), minimum > expires {
                requestedExpiry = minimum
                sendRegister(expires: minimum)
            } else {
                fail("Registrazione rifiutata (423): intervallo di registrazione non accettato.")
            }
        case 401, 407:
            fail("Credenziali rifiutate (\(code)): controlla Auth ID e password.")
        case 403:
            fail("Registrazione rifiutata (403 \(reason(response))): credenziali errate o accesso non consentito da questo indirizzo IP.")
        case 404:
            fail("Account sconosciuto al server (404): controlla il numero / ID.")
        default:
            fail("Registrazione rifiutata: \(code) \(reason(response)).")
        }
    }

    /// Updates the Contact address with Via received/rport when the server
    /// saw a different (NATed) source. Returns whether it changed.
    private func adoptPublicAddress(from response: SIPMessage) -> Bool {
        guard let via = response.headerValues("Via").first else { return false }
        let received = SIPHeader.parameter("received", in: via).flatMap { $0.isEmpty ? nil : $0 }
        let rport = SIPHeader.parameter("rport", in: via).flatMap { UInt16($0) }
        let address = received ?? contactAddress
        let port = rport ?? contactPort
        guard address != contactAddress || port != contactPort else { return false }
        behindNAT = true
        contactAddress = address
        contactPort = port
        if let current = binding?.components(separatedBy: " · ").first {
            binding = "\(current) · \(localAddress) → pubblico \(address):\(port)"
        }
        return true
    }

    private func grantedExpiry(in response: SIPMessage) -> Int? {
        let ours = response.headerValues("Contact").first {
            SIPHeader.uri(in: $0).contains("@\(contactAddress):\(contactPort)")
        }
        if let ours, let value = SIPHeader.parameter("expires", in: ours).flatMap(Int.init) { return value }
        return response.header("Expires").flatMap { Int($0) }
    }

    private func scheduleRefresh(after seconds: Int) {
        refreshTask?.cancel()
        let delay = max(Double(seconds) * 0.8, min(Double(seconds), 20))
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.registration.isRegistered else { return }
            self.sendRegister(expires: self.requestedExpiry)
        }
    }

    /// Keeps the NAT mapping open between registrations (RFC 5626 CRLF ping).
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, let socket = self.socket, let server = self.serverEndpoint else { return }
                socket.send(Data("\r\n\r\n".utf8), to: server)
            }
        }
    }

    private func fail(_ message: String) {
        log.error("SIP: \(message)")
        refreshTask?.cancel()
        closeSocket()
        registration = .failed(message)
    }

    private func closeSocket() {
        keepAliveTask?.cancel()
        refreshTask?.cancel()
        waitTask?.cancel()
        for transaction in transactions.values { transaction.cancel() }
        transactions.removeAll()
        if let current { finishCall(current, outcome: "Registrazione chiusa durante la chiamata.", success: false) }
        if case .waitingIncoming = call { call = .idle }
        socket?.close()
        socket = nil
        binding = nil
    }

    // MARK: Outgoing test call

    public func startOutgoingCall() {
        guard canCall else { return }
        let target = destination.filter { !$0.isWhitespace }
        let context: CallContext
        do {
            context = try CallContext(direction: .outgoing, callID: "\(SIPHeader.randomToken(12))@\(localAddress)",
                                      peer: target, interface: networkInterface)
        } catch {
            log.error("SIP: \(error.localizedDescription)")
            return
        }
        context.localParty = "<sip:\(account.number)@\(account.domain)>;tag=\(SIPHeader.randomToken(4))"
        context.remoteParty = "<sip:\(target)@\(account.domain)>"
        context.remoteTarget = "sip:\(target)@\(account.domain)"
        context.localSDP = SDPMedia.describe(address: contactAddress, port: Int(context.rtp.localPort),
                                             codecs: codecs, sessionID: context.sessionID)
        current = context
        report = nil
        call = .dialing(target)
        log.info("SIP: chiamata di prova verso \(target).")
        sendInvite(context)

        context.timer = Task { [weak self, weak context] in
            try? await Task.sleep(for: .seconds(Self.ringTimeout))
            guard let self, let context, !Task.isCancelled, !context.answered else { return }
            self.log.warning("SIP: nessuna risposta entro \(Int(Self.ringTimeout)) secondi.")
            context.pendingOutcome = "Nessuna risposta entro \(Int(Self.ringTimeout)) secondi."
            self.cancelInvite(context)
        }
    }

    private func sendInvite(_ context: CallContext) {
        let uri = context.remoteTarget
        send(method: "INVITE", uri: uri, build: { [unowned self, unowned context] auth in
            context.localCSeq += 1
            var extra = [
                ("Contact", "<sip:\(account.number)@\(contactAddress):\(contactPort)>"),
                ("Allow", Self.allow),
                ("Content-Type", "application/sdp"),
            ]
            if let auth { extra.append(auth) }
            let request = makeRequest("INVITE", uri: uri, from: context.localParty, to: context.remoteParty,
                                      callID: context.callID, cseq: context.localCSeq, extra: extra,
                                      body: Data(context.localSDP.utf8))
            context.invite = request
            return request
        }, onProvisional: { [unowned self, weak context] response in
            guard let context, current === context, let code = response.statusCode, code > 100 else { return }
            if case .dialing = call { call = .ringing(context.peer) }
            if code == 180 || code == 183 { log.info("SIP: \(code) \(reason(response)), il numero squilla.") }
        }, onFinal: { [unowned self, weak context] response in
            guard let context else { return }
            handleInviteFinal(response, context: context)
        }, onTimeout: { [unowned self, weak context] in
            guard let context else { return }
            finishCall(context, outcome: "Il server non ha risposto all’INVITE.", success: false)
        })
    }

    private func handleInviteFinal(_ response: SIPMessage, context: CallContext) {
        guard let code = response.statusCode else { return }
        guard (200..<300).contains(code) else {
            let outcome = context.pendingOutcome ?? Self.describeCallFailure(code: code, reason: reason(response))
            log.warning("SIP: chiamata terminata con \(code) \(reason(response)).")
            finishCall(context, outcome: outcome, success: false)
            return
        }
        // 2xx: the dialog is established.
        if let tag = response.header("To").flatMap({ SIPHeader.parameter("tag", in: $0) }) {
            context.remoteParty = "<sip:\(context.peer)@\(account.domain)>;tag=\(tag)"
        }
        if let contact = response.headerValues("Contact").first { context.remoteTarget = SIPHeader.uri(in: contact) }
        context.routeSet = response.headerValues("Record-Route").reversed()
        context.inviteCSeq = context.localCSeq
        sendAck(for: context)

        if context.pendingOutcome != nil || current !== context {
            // Answered after we gave up: hang up straight away.
            sendBye(context)
            return
        }
        guard startMedia(context, sdp: response.hasSDP ? response.bodyText : nil, offerWasOurs: true) else {
            context.pendingOutcome = "La risposta non contiene un codec G.711 utilizzabile."
            sendBye(context)
            return
        }
        answered(context)
    }

    private func sendAck(for context: CallContext) {
        var extra: [(String, String)] = context.routeSet.map { ("Route", $0) }
        extra.append(("Contact", "<sip:\(account.number)@\(contactAddress):\(contactPort)>"))
        let ack = makeRequest("ACK", uri: context.remoteTarget, from: context.localParty, to: context.remoteParty,
                              callID: context.callID, cseq: context.inviteCSeq, extra: extra)
        context.ack = ack
        transmit(ack)
    }

    private func cancelInvite(_ context: CallContext) {
        guard let invite = context.invite, let via = invite.headerValues("Via").first, let cseq = invite.cseq else { return }
        var cancel = SIPMessage(.request(method: "CANCEL", uri: invite.requestURI ?? context.remoteTarget), headers: [
            ("Via", via), ("Max-Forwards", "70"),
            ("From", invite.header("From") ?? ""), ("To", invite.header("To") ?? ""),
            ("Call-ID", context.callID), ("CSeq", "\(cseq.number) CANCEL"), ("User-Agent", Self.userAgent),
        ])
        for route in invite.headerValues("Route") { cancel.addHeader("Route", route) }
        call = .ending
        startTransaction(cancel, onProvisional: nil, onFinal: { _ in }, onTimeout: { [unowned self, weak context] in
            guard let context else { return }
            finishCall(context, outcome: context.pendingOutcome ?? "Chiamata annullata.", success: false)
        })
        // The 487 to the INVITE should follow; don't wait for it forever.
        context.timer?.cancel()
        context.timer = Task { [weak self, weak context] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, let context, !Task.isCancelled, !context.answered else { return }
            self.finishCall(context, outcome: context.pendingOutcome ?? "Chiamata annullata.", success: false)
        }
    }

    // MARK: Incoming test call

    public func waitForIncomingCall() {
        guard registration.isRegistered, call.isIdle else { return }
        report = nil
        call = .waitingIncoming
        log.info("SIP: in attesa di una chiamata verso \(account.number) (al massimo \(Int(Self.incomingWait / 60)) minuti).")
        waitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.incomingWait))
            guard let self, !Task.isCancelled, case .waitingIncoming = self.call else { return }
            self.call = .idle
            self.report = SIPCallReport(direction: .incoming, peer: "—", success: false,
                                        outcome: "Nessuna chiamata ricevuta entro \(Int(Self.incomingWait / 60)) minuti.", answered: false)
            self.log.warning("SIP: nessuna chiamata ricevuta.")
        }
    }

    public func hangUp() {
        if case .waitingIncoming = call {
            waitTask?.cancel()
            call = .idle
            log.info("SIP: attesa della chiamata annullata.")
            return
        }
        guard let context = current else { return }
        if context.answered {
            context.pendingOutcome = "Chiamata chiusa da te."
            sendBye(context)
        } else if context.direction == .outgoing {
            context.pendingOutcome = "Chiamata annullata prima della risposta."
            cancelInvite(context)
        } else if let invite = context.invite, let source = context.inviteSource {
            transmit(response(to: invite, code: 486, reason: "Busy Here", toTag: context.localTag), to: source)
            finishCall(context, outcome: "Chiamata rifiutata da te.", success: false)
        }
    }

    private func handleIncomingInvite(_ request: SIPMessage, from source: UDPEndpoint) {
        let callID = request.header("Call-ID") ?? ""
        if let context = current, context.callID == callID {
            if context.direction == .incoming, request.header("To").flatMap({ SIPHeader.parameter("tag", in: $0) }) == nil {
                // Retransmission of the initial INVITE.
                if let last = context.lastResponse { transmit(last, to: source) }
            } else {
                // Re-INVITE (session refresh, hold…): accept with the same media.
                if request.hasSDP, let media = SDPMedia.parse(request.bodyText),
                   let codec = media.firstCommonCodec(with: context.offeredCodecs),
                   let remote = UDPEndpoint(address: media.address, port: media.port), media.isActive {
                    context.rtp.update(remote: remote, codec: codec)
                }
                var ok = response(to: request, code: 200, reason: "OK", toTag: nil, body: Data(context.localSDP.utf8))
                ok.addHeader("Contact", "<sip:\(account.number)@\(contactAddress):\(contactPort)>")
                ok.addHeader("Content-Type", "application/sdp")
                transmit(ok, to: source)
            }
            return
        }
        guard case .waitingIncoming = call else {
            let busy = current != nil
            transmit(response(to: request, code: busy ? 486 : 480, reason: busy ? "Busy Here" : "Temporarily Unavailable",
                              toTag: SIPHeader.randomToken(4)), to: source)
            return
        }
        let offer = request.hasSDP ? SDPMedia.parse(request.bodyText) : nil
        if let offer, offer.firstCommonCodec(with: codecs) == nil {
            transmit(response(to: request, code: 488, reason: "Not Acceptable Here", toTag: SIPHeader.randomToken(4)), to: source)
            log.warning("SIP: chiamata in arrivo senza codec G.711, rifiutata (488).")
            return
        }

        let from = request.header("From") ?? ""
        let caller = SIPHeader.displayName(in: from).map { "\($0) (\(SIPHeader.user(in: SIPHeader.uri(in: from)) ?? ""))" }
            ?? SIPHeader.user(in: SIPHeader.uri(in: from)) ?? "sconosciuto"
        let context: CallContext
        do {
            context = try CallContext(direction: .incoming, callID: callID, peer: caller, interface: networkInterface)
        } catch {
            transmit(response(to: request, code: 500, reason: "Server Internal Error", toTag: SIPHeader.randomToken(4)), to: source)
            log.error("SIP: \(error.localizedDescription)")
            return
        }
        waitTask?.cancel()
        context.localTag = SIPHeader.randomToken(4)
        context.localParty = "\(request.header("To") ?? "");tag=\(context.localTag)"
        context.remoteParty = from
        context.remoteTarget = request.headerValues("Contact").first.map(SIPHeader.uri(in:)) ?? SIPHeader.uri(in: from)
        context.routeSet = request.headerValues("Record-Route")
        context.invite = request
        context.inviteSource = source
        context.remoteOffer = offer
        current = context
        call = .answering(caller)
        log.info("SIP: chiamata in arrivo da \(caller).")

        transmit(response(to: request, code: 100, reason: "Trying", toTag: nil), to: source)
        let ringing = response(to: request, code: 180, reason: "Ringing", toTag: context.localTag)
        context.lastResponse = ringing
        transmit(ringing, to: source)

        context.timer = Task { [weak self, weak context] in
            try? await Task.sleep(for: Self.answerDelay)
            guard let self, let context, !Task.isCancelled, self.current === context else { return }
            self.answer(context)
        }
    }

    private func answer(_ context: CallContext) {
        guard let invite = context.invite, let source = context.inviteSource else { return }
        // With an offer, answer with the one codec chosen; without (late
        // offer), offer ours and expect the answer in the ACK.
        let chosen = context.remoteOffer?.firstCommonCodec(with: codecs)
        context.offeredCodecs = chosen.map { [$0] } ?? codecs
        context.localSDP = SDPMedia.describe(address: contactAddress, port: Int(context.rtp.localPort),
                                             codecs: context.offeredCodecs, sessionID: context.sessionID)
        var ok = response(to: invite, code: 200, reason: "OK", toTag: context.localTag, body: Data(context.localSDP.utf8))
        ok.addHeader("Contact", "<sip:\(account.number)@\(contactAddress):\(contactPort)>")
        ok.addHeader("Allow", Self.allow)
        ok.addHeader("Content-Type", "application/sdp")
        context.lastResponse = ok
        context.localCSeq = 0
        transmit(ok, to: source)

        if let offer = context.remoteOffer {
            guard startMedia(context, sdp: nil, offer: offer) else { return }
        }
        answered(context)

        // Retransmit the 200 until the ACK arrives (RFC 3261 §13.3.1.4).
        context.retransmit = Task { [weak self, weak context] in
            var interval = 0.5
            var elapsed = 0.0
            while elapsed < 32 {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, let context, !Task.isCancelled, !context.acknowledged else { return }
                self.transmit(ok, to: source)
                elapsed += interval
                interval = min(interval * 2, 4)
            }
            guard let self, let context, !context.acknowledged, self.current === context else { return }
            context.pendingOutcome = "Il chiamante non ha confermato la risposta (ACK mancante)."
            self.sendBye(context)
        }
    }

    // MARK: Media and call end

    /// Starts the echo audio from the remote SDP; false when no usable codec.
    @discardableResult
    private func startMedia(_ context: CallContext, sdp: String?, offer: SDPMedia? = nil, offerWasOurs: Bool = false) -> Bool {
        guard let media = offer ?? sdp.flatMap(SDPMedia.parse),
              let codec = media.firstCommonCodec(with: offerWasOurs ? codecs : context.offeredCodecs.isEmpty ? codecs : context.offeredCodecs),
              let remote = UDPEndpoint(address: media.address, port: media.port) else { return false }
        context.codec = codec
        context.remoteMedia = remote.description
        context.rtp.start(remote: remote, codec: codec)
        log.info("SIP: audio \(codec.displayName) verso \(remote): due toni, poi eco di quello che dici.")
        return true
    }

    private func answered(_ context: CallContext) {
        context.answered = true
        context.answeredAt = Date()
        context.timer?.cancel()
        call = .active(context.direction, peer: context.peer, since: Date())
        log.info("SIP: chiamata attiva con \(context.peer). Chiusura automatica dopo \(Int(Self.maxCallDuration)) secondi.")
        context.timer = Task { [weak self, weak context] in
            try? await Task.sleep(for: .seconds(Self.maxCallDuration))
            guard let self, let context, !Task.isCancelled, self.current === context else { return }
            context.pendingOutcome = "Chiamata chiusa dopo \(Int(Self.maxCallDuration)) secondi di prova."
            self.sendBye(context)
        }
        statsTask?.cancel()
        statsTask = Task { [weak self, weak context] in
            while !Task.isCancelled {
                guard let self, let context, self.current === context else { return }
                let stats = context.rtp.stats
                self.audio = SIPAudioStats(sent: stats.sent, received: stats.received, peakLevel: stats.peakLevel)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func sendBye(_ context: CallContext) {
        guard !context.byeSent else { return }
        context.byeSent = true
        if current === context { call = .ending }
        send(method: "BYE", uri: context.remoteTarget, build: { [unowned self, unowned context] auth in
            context.localCSeq += 1
            var extra: [(String, String)] = context.routeSet.map { ("Route", $0) }
            if let auth { extra.append(auth) }
            return makeRequest("BYE", uri: context.remoteTarget, from: context.localParty, to: context.remoteParty,
                               callID: context.callID, cseq: context.localCSeq, extra: extra)
        }, onFinal: { [unowned self, weak context] _ in
            guard let context else { return }
            finishCall(context, outcome: context.pendingOutcome ?? "Chiamata chiusa.", success: context.answered)
        }, onTimeout: { [unowned self, weak context] in
            guard let context else { return }
            finishCall(context, outcome: context.pendingOutcome ?? "Chiamata chiusa (il BYE non ha avuto risposta).", success: context.answered)
        })
    }

    private func finishCall(_ context: CallContext, outcome: String, success: Bool) {
        guard current === context else { return }
        context.timer?.cancel()
        context.retransmit?.cancel()
        statsTask?.cancel()
        let stats = context.rtp.stats
        context.rtp.stop()
        current = nil
        audio = nil
        call = .idle

        var result = SIPCallReport(direction: context.direction, peer: context.peer, success: success, outcome: outcome,
                                   answered: context.answered)
        result.duration = context.answeredAt.map { Date().timeIntervalSince($0) }
        result.codec = context.codec?.displayName
        result.remoteMedia = stats.source ?? context.remoteMedia
        result.packetsSent = stats.sent
        result.packetsReceived = stats.received
        result.peakLevel = stats.peakLevel
        if context.answered {
            if stats.received == 0 {
                result.success = false
                result.outcome += " Nessun audio ricevuto dall’altra parte: RTP bloccato (firewall/NAT) o codec non accettato."
            } else if (stats.peakLevel ?? -96) < -50 {
                result.outcome += " Audio ricevuto ma quasi silenzioso: prova a parlare durante il test."
            }
        }
        report = result
        let audioSummary = context.answered ? " Audio: \(stats.sent) pacchetti inviati, \(stats.received) ricevuti." : ""
        if result.success { log.info("SIP: \(result.outcome)\(audioSummary)") } else { log.warning("SIP: \(result.outcome)\(audioSummary)") }
    }

    private func endCallForShutdown() async {
        guard let context = current else { return }
        hangUp()
        for _ in 0..<20 where current === context {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if current === context { finishCall(context, outcome: "Chiamata chiusa.", success: context.answered) }
    }

    nonisolated static func describeCallFailure(code: Int, reason: String) -> String {
        switch code {
        case 403: "Chiamata non autorizzata (403): la linea non può chiamare questo numero o le chiamate uscenti non sono abilitate."
        case 404, 484: "Numero inesistente o incompleto (\(code))."
        case 408: "Il numero chiamato non risponde (408)."
        case 480: "Numero non raggiungibile (480)."
        case 486, 600: "Numero occupato (\(code))."
        case 487: "Chiamata annullata."
        case 488, 606: "Codec non accettato dal provider (\(code)): serve G.711."
        case 503: "Servizio non disponibile (503): il provider rifiuta temporaneamente la chiamata."
        case 401, 407: "Credenziali rifiutate per la chiamata (\(code))."
        default: "Chiamata non riuscita: \(code) \(reason)."
        }
    }

    // MARK: Receiving

    private func receive(_ data: Data, from source: UDPEndpoint) {
        // Keep-alive pongs and stray bytes.
        guard data.count > 4, let message = SIPMessage.parse(data) else { return }
        record(message, incoming: true, peer: source)
        if message.statusCode != nil {
            handleResponse(message)
        } else {
            handleRequest(message, from: source)
        }
    }

    private func handleResponse(_ response: SIPMessage) {
        guard let branch = response.topBranch, let cseq = response.cseq else { return }
        if let transaction = transactions[branch + cseq.method] {
            transaction.receive(response)
            return
        }
        // A retransmitted 2xx to our INVITE: the ACK got lost.
        if cseq.method == "INVITE", let code = response.statusCode, (200..<300).contains(code),
           let context = current, context.callID == response.header("Call-ID"), let ack = context.ack {
            transmit(ack)
        }
    }

    private func handleRequest(_ request: SIPMessage, from source: UDPEndpoint) {
        guard let method = request.method else { return }
        let callID = request.header("Call-ID")
        let context = current.flatMap { $0.callID == callID ? $0 : nil }
        switch method {
        case "INVITE":
            handleIncomingInvite(request, from: source)
        case "ACK":
            guard let context, context.direction == .incoming else { return }
            context.acknowledged = true
            context.retransmit?.cancel()
            if context.remoteOffer == nil, request.hasSDP, context.codec == nil {
                if !startMedia(context, sdp: request.bodyText) {
                    context.pendingOutcome = "L’ACK non contiene un codec G.711 utilizzabile."
                    sendBye(context)
                }
            }
        case "BYE":
            guard let context else {
                transmit(response(to: request, code: 481, reason: "Call/Transaction Does Not Exist", toTag: nil), to: source)
                return
            }
            transmit(response(to: request, code: 200, reason: "OK", toTag: nil), to: source)
            let who = context.direction == .outgoing ? "Il chiamato" : "Il chiamante"
            finishCall(context, outcome: context.pendingOutcome ?? "\(who) ha riagganciato.", success: context.answered)
        case "CANCEL":
            guard let context, context.direction == .incoming, !context.answered, let invite = context.invite,
                  invite.topBranch == request.topBranch else {
                transmit(response(to: request, code: 481, reason: "Call/Transaction Does Not Exist", toTag: nil), to: source)
                return
            }
            transmit(response(to: request, code: 200, reason: "OK", toTag: nil), to: source)
            transmit(response(to: invite, code: 487, reason: "Request Terminated", toTag: context.localTag), to: source)
            finishCall(context, outcome: "Il chiamante ha riagganciato prima della risposta.", success: false)
        case "OPTIONS":
            var ok = response(to: request, code: 200, reason: "OK", toTag: nil)
            ok.addHeader("Allow", Self.allow)
            ok.addHeader("Accept", "application/sdp")
            transmit(ok, to: source)
        case "NOTIFY", "INFO", "UPDATE":
            transmit(response(to: request, code: 200, reason: "OK", toTag: nil), to: source)
        default:
            transmit(response(to: request, code: 501, reason: "Not Implemented", toTag: nil), to: source)
        }
    }

    // MARK: Transactions

    static let allow = "INVITE, ACK, CANCEL, BYE, OPTIONS, NOTIFY, INFO, UPDATE"

    /// Sends a request and, on a 401/407 challenge, once more with digest
    /// credentials (`build` is called again and must bump the CSeq).
    private func send(method: String, uri: String,
                      build: @escaping ((name: String, value: String)?) -> SIPMessage,
                      onProvisional: ((SIPMessage) -> Void)? = nil,
                      onFinal: @escaping (SIPMessage) -> Void,
                      onTimeout: @escaping () -> Void,
                      authAttempted: Bool = false) {
        startTransaction(build(nil), onProvisional: onProvisional, onFinal: { [unowned self] response in
            let code = response.statusCode ?? 0
            let header = code == 401 ? "WWW-Authenticate" : "Proxy-Authenticate"
            if (code == 401 || code == 407), !authAttempted,
               let challenge = response.headerFields(header).compactMap(DigestChallenge.parse).first(where: \.isSupported) {
                let value = challenge.authorization(method: method, uri: uri, username: account.authUser, password: account.password)
                let name = code == 401 ? "Authorization" : "Proxy-Authorization"
                startTransaction(build((name, value)), onProvisional: onProvisional, onFinal: onFinal, onTimeout: onTimeout)
                return
            }
            onFinal(response)
        }, onTimeout: onTimeout)
    }

    private func startTransaction(_ request: SIPMessage, onProvisional: ((SIPMessage) -> Void)?,
                                  onFinal: @escaping (SIPMessage) -> Void, onTimeout: @escaping () -> Void) {
        guard let branch = request.topBranch, let method = request.method else { return }
        let key = branch + method
        let transaction = ClientTransaction()
        transaction.onResponse = { [unowned self] response in
            guard let code = response.statusCode else { return }
            if code < 200 {
                onProvisional?(response)
                return
            }
            transactions[key] = nil
            if method == "INVITE", code >= 300 { acknowledgeFailure(response, to: request) }
            onFinal(response)
        }
        transaction.onTimeout = { [unowned self] in
            transactions[key] = nil
            onTimeout()
        }
        transactions[key] = transaction
        transmit(request)
        transaction.start(isInvite: method == "INVITE") { [weak self] in self?.transmit(request) }
    }

    /// ACK for a non-2xx final response: same branch, hop by hop (§17.1.1.3).
    private func acknowledgeFailure(_ response: SIPMessage, to invite: SIPMessage) {
        guard let via = invite.headerValues("Via").first, let cseq = invite.cseq else { return }
        var ack = SIPMessage(.request(method: "ACK", uri: invite.requestURI ?? ""), headers: [
            ("Via", via), ("Max-Forwards", "70"),
            ("From", invite.header("From") ?? ""), ("To", response.header("To") ?? invite.header("To") ?? ""),
            ("Call-ID", invite.header("Call-ID") ?? ""), ("CSeq", "\(cseq.number) ACK"), ("User-Agent", Self.userAgent),
        ])
        for route in invite.headerValues("Route") { ack.addHeader("Route", route) }
        transmit(ack)
    }

    // MARK: Building and sending

    private func makeRequest(_ method: String, uri: String, from: String, to: String, callID: String, cseq: Int,
                             extra: [(String, String)] = [], body: Data = Data()) -> SIPMessage {
        var headers: [(String, String)] = [
            ("Via", "SIP/2.0/UDP \(contactAddress):\(contactPort);branch=z9hG4bK\(SIPHeader.randomToken(8));rport"),
            ("Max-Forwards", "70"),
            ("From", from), ("To", to), ("Call-ID", callID), ("CSeq", "\(cseq) \(method)"),
            ("User-Agent", Self.userAgent),
        ]
        headers += extra
        return SIPMessage(.request(method: method, uri: uri), headers: headers, body: body)
    }

    private func response(to request: SIPMessage, code: Int, reason: String, toTag: String?, body: Data = Data()) -> SIPMessage {
        var headers: [(String, String)] = request.headerValues("Via").map { ("Via", $0) }
        var to = request.header("To") ?? ""
        if let toTag, SIPHeader.parameter("tag", in: to) == nil { to += ";tag=\(toTag)" }
        headers += [
            ("From", request.header("From") ?? ""), ("To", to),
            ("Call-ID", request.header("Call-ID") ?? ""), ("CSeq", request.header("CSeq") ?? ""),
            ("Server", Self.userAgent),
        ]
        if (200..<300).contains(code), request.method == "INVITE" {
            headers += request.headerValues("Record-Route").map { ("Record-Route", $0) }
        }
        return SIPMessage(.response(code: code, reason: reason), headers: headers, body: body)
    }

    /// Requests go to the server (outbound proxy), responses back to the
    /// source of the request (rport, RFC 3581).
    private func transmit(_ message: SIPMessage, to endpoint: UDPEndpoint? = nil) {
        guard let socket, let target = endpoint ?? serverEndpoint else { return }
        record(message, incoming: false, peer: target)
        socket.send(message.serialized(), to: target)
    }

    private func record(_ message: SIPMessage, incoming: Bool, peer: UDPEndpoint) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        let arrow = incoming ? "← da \(peer)" : "→ a \(peer)"
        trace.append("──── \(stamp) \(arrow)\n\(message.redactedText)")
        if trace.count > 300 { trace.removeFirst(trace.count - 300) }
    }

    private func reason(_ response: SIPMessage) -> String {
        if case .response(_, let reason) = response.start { return reason }
        return ""
    }
}

// MARK: - Support types

private struct Account {
    var number: String
    var authUser: String
    var password: String
    /// host or host:port used in URIs.
    var domain: String
}

/// Retransmissions of one client request over UDP (timers A/B/E/F, RFC 3261
/// §17.1): T1 = 500 ms doubling (capped at 4 s for non-INVITE), timeout after
/// 32 s. A provisional response stops retransmissions; an INVITE then waits
/// for its final response without a timeout (the caller rings it off).
@MainActor
private final class ClientTransaction {
    var onResponse: ((SIPMessage) -> Void)?
    var onTimeout: (() -> Void)?
    private var task: Task<Void, Never>?
    private var provisional = false

    func start(isInvite: Bool, retransmit: @escaping () -> Void) {
        task = Task { [weak self] in
            var interval = 0.5
            var elapsed = 0.0
            while elapsed < 32 {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                if self.provisional {
                    if isInvite { return }
                } else {
                    retransmit()
                }
                elapsed += interval
                interval = isInvite ? interval * 2 : min(interval * 2, 4)
            }
            guard let self, !Task.isCancelled else { return }
            self.onTimeout?()
        }
    }

    func receive(_ response: SIPMessage) {
        if let code = response.statusCode, code >= 200 {
            task?.cancel()
        } else {
            provisional = true
        }
        onResponse?(response)
    }

    func cancel() {
        task?.cancel()
        onResponse = nil
        onTimeout = nil
    }
}

/// One test call and its dialog.
@MainActor
private final class CallContext {
    let direction: SIPCallDirection
    let callID: String
    let peer: String
    let rtp: RTPStream
    let sessionID = UInt64.random(in: 1...UInt64(Int64.max))

    var localTag = ""
    /// From of our requests (To of theirs), with our tag.
    var localParty = ""
    /// To of our requests (From of theirs), with their tag once known.
    var remoteParty = ""
    var remoteTarget = ""
    var routeSet: [String] = []
    var localCSeq = 0
    var inviteCSeq = 0
    var localSDP = ""
    var offeredCodecs: [RTPCodec] = []

    var invite: SIPMessage?
    var inviteSource: UDPEndpoint?
    var remoteOffer: SDPMedia?
    var lastResponse: SIPMessage?
    var ack: SIPMessage?

    var answered = false
    var answeredAt: Date?
    var acknowledged = false
    var byeSent = false
    var codec: RTPCodec?
    var remoteMedia: String?
    var pendingOutcome: String?
    var timer: Task<Void, Never>?
    var retransmit: Task<Void, Never>?

    init(direction: SIPCallDirection, callID: String, peer: String, interface: String?) throws {
        self.direction = direction
        self.callID = callID
        self.peer = peer
        self.rtp = try RTPStream(interface: interface)
    }
}
