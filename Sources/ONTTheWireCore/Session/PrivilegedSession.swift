import Foundation

public enum PrivilegedSessionError: Error, LocalizedError, Equatable {
    case authorizationCancelled
    case componentMissing(String)
    case launchFailed(String)
    case invalidCredentials

    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            "Autorizzazione amministratore annullata."
        case .componentMissing(let name):
            "Componente mancante: \(name). Ricrea l’app con scripts/build-app.sh."
        case .launchFailed(let detail):
            "Avvio della sessione non riuscito: \(detail)"
        case .invalidCredentials:
            "Username e password non possono contenere a capo."
        }
    }
}

/// Runs one PPPoE session as root: the `RootBroker` starts `ont-session.sh`,
/// which runs pppd with pppoe-relay as its transport. The app follows the
/// session by reading the log files in a private session folder, and stops it
/// by creating a `stop` file there.
@MainActor
public final class PrivilegedSession {
    public struct Parameters: Sendable {
        public var interface: String
        public var vlanID: Int?
        public var useAsPrimary: Bool
        public var username: String
        public var password: String

        public init(interface: String, vlanID: Int?, useAsPrimary: Bool, username: String, password: String) {
            self.interface = interface
            self.vlanID = vlanID
            self.useAsPrimary = useAsPrimary
            self.username = username
            self.password = password
        }
    }

    public var onEvent: ((SessionEvent) -> Void)?
    /// Called once when the root supervisor has finished, with pppd's exit status.
    public var onExit: ((Int?) -> Void)?

    public private(set) var isRunning = false

    private var directory: URL?
    private var timer: Timer?
    private var launchedAt = Date.distantPast
    private var supervisorSeen = false
    private var offsets: [String: UInt64] = [:]
    private var buffers: [String: LineBuffer] = [:]

    static let supervisorStartTimeout: TimeInterval = 10

    private let broker: RootBroker

    public init(broker: RootBroker) {
        self.broker = broker
    }

    public func start(_ parameters: Parameters) async throws {
        guard !parameters.username.contains(where: \.isNewline), !parameters.password.contains(where: \.isNewline) else {
            throw PrivilegedSessionError.invalidCredentials
        }
        try await broker.start()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTTheWire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let secret = dir.appendingPathComponent("secret")
        let contents = "user \(Self.pppdQuoted(parameters.username))\npassword \(Self.pppdQuoted(parameters.password))\n"
        guard FileManager.default.createFile(atPath: secret.path, contents: Data(contents.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: dir)
            throw PrivilegedSessionError.launchFailed("impossibile preparare la cartella di sessione")
        }

        do {
            try await broker.startSession(
                directory: dir, interface: parameters.interface,
                vlanID: parameters.vlanID, useAsPrimary: parameters.useAsPrimary)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        directory = dir
        offsets = [:]
        buffers = [:]
        launchedAt = Date()
        supervisorSeen = false
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Asks the root supervisor to end the session (PADT is sent on the way out).
    public func stop() {
        guard let directory, isRunning else { return }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("stop").path, contents: nil)
    }

    /// Stops following a supervisor that does not answer. It still exits on
    /// its own when the app quits.
    public func abandon() {
        guard isRunning else { return }
        stop()
        finish(status: nil)
    }

    // MARK: Monitoring

    private func poll() {
        guard let directory else { return }
        for line in readNewLines("relay.log", in: directory) {
            if let event = SessionLogParser.parseRelayLine(line) { onEvent?(event) }
        }
        for line in readNewLines("pppd.log", in: directory) {
            if let event = SessionLogParser.parsePPPDLine(line) { onEvent?(event) }
        }
        let exitFile = directory.appendingPathComponent("exit")
        if let text = try? String(contentsOf: exitFile, encoding: .utf8) {
            finish(status: Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }
        if !supervisorSeen {
            supervisorSeen = FileManager.default.fileExists(atPath: directory.appendingPathComponent("supervisor.pid").path)
            if !supervisorSeen, Date().timeIntervalSince(launchedAt) > Self.supervisorStartTimeout {
                let log = (try? String(contentsOf: directory.appendingPathComponent("supervisor.log"), encoding: .utf8)) ?? ""
                onEvent?(.supervisorFailed(log.trimmingCharacters(in: .whitespacesAndNewlines)))
                finish(status: nil)
            }
        }
    }

    private func finish(status: Int?) {
        timer?.invalidate()
        timer = nil
        isRunning = false
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        onExit?(status)
    }

    private func readNewLines(_ name: String, in directory: URL) -> [String] {
        let url = directory.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let offset = offsets[name] ?? 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offsets[name] = offset + UInt64(data.count)
        var buffer = buffers[name] ?? LineBuffer()
        let lines = buffer.append(String(decoding: data, as: UTF8.self))
        buffers[name] = buffer
        return lines
    }

    // MARK: Helpers

    /// Finds a helper inside the app bundle, or next to the executable when
    /// running from `swift run`.
    static func locate(_ name: String) throws -> URL {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let executableDir { candidates.append(executableDir.appendingPathComponent(name)) }
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw PrivilegedSessionError.componentMissing(name)
    }

    /// Quotes a value for a pppd options file.
    nonisolated static func pppdQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
