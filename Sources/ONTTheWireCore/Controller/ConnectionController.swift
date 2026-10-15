import Foundation
import Observation

/// Coordinates settings, credentials and the PPPoE session, and exposes a
/// single state for the UI.
///
/// Nothing the user types is persisted: every launch starts with empty fields,
/// and credentials live only in memory while the app runs.
@MainActor
@Observable
public final class ConnectionController {
    public static let connectTimeout: Duration = .seconds(75)

    public var settings = ConnectionSettings()
    public var password = ""

    public private(set) var state: ConnectionState = .idle
    /// Details of the running session, for the summary.
    public private(set) var details = SessionDetails()

    public let catalog: InterfaceCatalog
    public let log: LogStore
    public let speedTest = SpeedTest()

    @ObservationIgnored private let broker: RootBroker
    @ObservationIgnored private let session: PrivilegedSession
    @ObservationIgnored private var attemptID = UUID()
    @ObservationIgnored private var userRequestedStop = false
    /// The most specific reason seen so far for a failure, reported when the
    /// session ends.
    @ObservationIgnored private var failureReason: String?

    public init(catalog: InterfaceCatalog? = nil, log: LogStore? = nil) {
        let catalog = catalog ?? InterfaceCatalog()
        self.catalog = catalog
        self.log = log ?? LogStore()
        let broker = RootBroker()
        self.broker = broker
        self.session = PrivilegedSession(broker: broker)

        speedTest.onFinish = { [weak self] result in self?.logSpeedTest(result) }
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onExit = { [weak self] status in self?.handleExit(status) }
        catalog.onLinkChange = { [weak self] bsd, active in self?.handleLinkChange(bsd, active: active) }

    }

    // MARK: Derived state

    public var problems: [SettingsProblem] {
        SettingsValidator.problems(settings: settings, password: password, availableInterfaces: catalog.interfaces)
    }

    public var canConnect: Bool {
        problems.isEmpty && !state.isBusy && !state.isSessionActive
    }

    public var canDisconnect: Bool {
        state.isSessionActive
    }

    /// Whether the administrator authorization for this app run is in place.
    public private(set) var isAuthorized = false

    // MARK: Actions

    /// Asks once for administrator authorization (password or Touch ID) and
    /// starts the root broker used by every later connect/disconnect.
    public func authorize() async {
        guard !isAuthorized else { return }
        do {
            try await broker.start()
            isAuthorized = true
            log.info("Autorizzazione amministratore ottenuta: valida finché l’app resta aperta.")
        } catch PrivilegedSessionError.authorizationCancelled {
            log.warning("Autorizzazione annullata: verrà richiesta alla prima connessione.")
        } catch {
            log.error(error.localizedDescription)
        }
    }

    public func connect() async {
        guard canConnect, let interface = settings.interfaceBSDName else { return }
        let username = settings.username.trimmingCharacters(in: .whitespaces)
        let attempt = UUID()
        attemptID = attempt
        userRequestedStop = false
        failureReason = nil
        details = SessionDetails(interface: interface, vlanID: settings.vlanID)

        let tag = settings.vlanID.map { "VLAN \($0)" } ?? "senza VLAN"
        log.info("Connessione su \(interface), \(tag).")
        state = .preparing

        do {
            try await session.start(.init(
                interface: interface, vlanID: settings.vlanID, useAsPrimary: settings.useAsPrimary,
                username: username, password: password))
        } catch PrivilegedSessionError.authorizationCancelled {
            log.warning("Autorizzazione annullata: nessuna sessione avviata.")
            state = .idle
            return
        } catch {
            isAuthorized = broker.isReady
            log.error(error.localizedDescription)
            state = .failed(error.localizedDescription)
            return
        }
        isAuthorized = true

        guard attemptID == attempt else { return }
        state = .searchingServer
        scheduleWatchdog(for: attempt)
    }

    /// The speed test runs on the PPP interface, so only while connected.
    public var canRunSpeedTest: Bool {
        if case .connected = state { return details.pppInterface != nil }
        return false
    }

    public func startSpeedTest() {
        guard canRunSpeedTest, let interface = details.pppInterface else { return }
        log.info("Test di velocità su \(interface) con \(speedTest.streams) flussi paralleli.")
        speedTest.start(interface: interface)
    }

    public func disconnect() async {
        guard state.isSessionActive else { return }
        speedTest.cancel()
        userRequestedStop = true
        attemptID = UUID()
        state = .disconnecting
        log.info("Disconnessione richiesta.")
        await stopAndWait()
    }


    public func clearError() {
        if case .failed = state { state = .idle }
    }

    /// Called when the app is about to quit.
    public func prepareForTermination() async {
        guard session.isRunning else { return }
        userRequestedStop = true
        attemptID = UUID()
        await stopAndWait()
    }

    public var needsTerminationWork: Bool {
        session.isRunning
    }

    // MARK: Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .discoveryStarted(let interface, let mac, let vlan):
            let tag = vlan.map { "VLAN \($0)" } ?? "senza tag"
            log.info("Ricerca del server PPPoE su \(interface) (\(tag), MAC \(mac)).")
            if !state.isTerminal { state = .searchingServer }
        case .serverOffered(let mac, let acName):
            log.info("Risposta dal concentratore \(acName.isEmpty ? mac : "\(acName) (\(mac))").")
            details.concentrator = acName.isEmpty ? mac : acName
        case .sessionOpened(let id, _):
            log.info("Sessione PPPoE \(id) aperta, negoziazione del collegamento.")
            details.sessionID = id
            if !state.isTerminal { state = .authenticating }
        case .noServer:
            failureReason = "Nessun server PPPoE ha risposto: verifica VLAN ID, cavo e che l’ONT sia acceso e allineato."
        case .discoveryError(let text):
            log.warning("Errore dal concentratore: \(text)")
            failureReason = "Il concentratore ha rifiutato la sessione (\(text))."
        case .serverClosedSession:
            log.warning("Il concentratore ha chiuso la sessione (PADT).")
            if failureReason == nil { failureReason = "Il concentratore ha chiuso la sessione." }
        case .linkInterface(let name):
            details.pppInterface = name
        case .authenticating(let method):
            log.info("Autenticazione \(method) in corso.")
            if !state.isTerminal { state = .authenticating }
        case .authenticated:
            log.info("Autenticazione riuscita, negoziazione dell’indirizzo IP.")
            if !state.isTerminal { state = .configuringNetwork }
        case .authenticationFailed:
            log.error("Autenticazione rifiutata dal server.")
            failureReason = "Autenticazione rifiutata: controlla username e password."
        case .localAddress(let address):
            details.localAddress = address
            log.info("Indirizzo assegnato: \(address).")
            if !state.isTerminal { state = .connected(addresses: [address]) }
        case .remoteAddress(let address):
            details.remoteAddress = address
            log.info("Gateway: \(address).")
        case .dnsServer(let address):
            if !details.dnsServers.contains(address) { details.dnsServers.append(address) }
            log.info("DNS dell’operatore: \(address).")
        case .primaryPublished:
            log.info("Il PPPoE è ora la connessione principale (route predefinita e DNS).")
        case .echoTimeout:
            log.warning("Il server non risponde più agli LCP echo.")
            failureReason = "Il server PPPoE ha smesso di rispondere."
        case .peerTerminated:
            log.warning("Il server ha chiuso il collegamento PPP.")
            if failureReason == nil { failureReason = "Il server ha chiuso il collegamento." }
        case .terminated:
            break
        case .supervisorFailed(let detail):
            failureReason = "La sessione non è partita" + (detail.isEmpty ? "." : ": \(detail)")
        }
    }

    private func handleExit(_ status: Int?) {
        speedTest.cancel()
        log.info("Sessione terminata (pppd \(status.map(String.init) ?? "–")).")
        let wasConnected: Bool = { if case .connected = state { return true }; return false }()
        defer { details.endSession() }

        if userRequestedStop || state == .disconnecting {
            state = .idle
            return
        }
        attemptID = UUID()
        let message = failureReason ?? Self.describe(pppdStatus: status, wasConnected: wasConnected)
        log.error(message)
        state = .failed(message)
    }

    private func handleLinkChange(_ bsdName: String, active: Bool) {
        guard bsdName == (details.interface ?? settings.interfaceBSDName) else { return }
        log.info("Collegamento Ethernet su \(bsdName): \(active ? "attivo" : "non attivo").")
        if !active, session.isRunning {
            failureReason = "Collegamento Ethernet perso: adattatore scollegato, cavo rimosso o ONT spento."
            session.stop()
        }
    }

    private func scheduleWatchdog(for attempt: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard let self, self.attemptID == attempt, self.session.isRunning else { return }
            if case .connected = self.state { return }
            self.failureReason = self.failureReason ?? "Connessione non stabilita entro 75 secondi."
            self.session.stop()
        }
    }

    /// Asks the supervisor to stop and waits (at most 15 s) for it to exit.
    private func stopAndWait() async {
        session.stop()
        for _ in 0..<60 where session.isRunning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if session.isRunning {
            log.warning("La sessione non ha confermato la chiusura entro 15 secondi.")
            session.abandon()
        }
    }

    private func logSpeedTest(_ result: SpeedTestResult) {
        func mbps(_ value: Double?) -> String { value.map { String(format: "%.1f Mbps", $0) } ?? "–" }
        let ping = result.pingMs.map { String(format: "%.1f ms", $0) } ?? "–"
        log.info("Test di velocità (\(result.streams) flussi): download \(mbps(result.downloadMbps)), upload \(mbps(result.uploadMbps)), ping \(ping).")
        for warning in result.warnings { log.warning("Test di velocità: \(warning)") }
    }

    /// pppd exit codes from pppd(8).
    nonisolated static func describe(pppdStatus: Int?, wasConnected: Bool) -> String {
        switch pppdStatus {
        case 19: "Autenticazione rifiutata: controlla username e password."
        case 8: "Nessun server PPPoE ha risposto: verifica VLAN ID, cavo e ONT."
        case 15: "Il server PPPoE ha smesso di rispondere."
        case 16: "Linea caduta."
        case 2: "Opzioni PPP non valide."
        case 10: "Negoziazione PPP non riuscita: il server non risponde alle richieste LCP."
        default: wasConnected ? "Connessione interrotta." : "Connessione non riuscita."
        }
    }
}

/// What is known about the current (or last) session.
public struct SessionDetails: Equatable, Sendable {
    public var interface: String?
    public var vlanID: Int?
    public var concentrator: String?
    public var sessionID: Int?
    public var pppInterface: String?
    public var localAddress: String?
    public var remoteAddress: String?
    public var dnsServers: [String] = []

    public init(interface: String? = nil, vlanID: Int? = nil) {
        self.interface = interface
        self.vlanID = vlanID
    }

    mutating func endSession() {
        sessionID = nil
        pppInterface = nil
        localAddress = nil
        remoteAddress = nil
        dnsServers = []
    }
}
