import Darwin
import Foundation
import Security

/// The app's single root process. One administrator authorization (password
/// or Touch ID, as the system dialog allows) starts ont-root-helper, which
/// runs ont-broker.sh as root for the rest of the app's life. Commands travel
/// over the private pipe returned by AuthorizationExecuteWithPrivileges, so
/// only this app can start sessions through it.
@MainActor
public final class RootBroker {
    public private(set) var isReady = false

    private var pipe: Pipe?
    private var authorization: AuthorizationRef?
    /// Serializes request/response exchanges on the pipe, off the main thread.
    private let queue = DispatchQueue(label: "it.ontthewire.broker")

    public init() {}

    /// Shows the authorization dialog and starts the broker. Does nothing if
    /// the broker is already running.
    public func start() async throws {
        if isReady, (try? await send("PING")) == "PONG" { return }
        close()

        let helper = try PrivilegedSession.locate("ont-root-helper")
        let broker = try PrivilegedSession.locate("ont-broker.sh")
        let pid = String(ProcessInfo.processInfo.processIdentifier)

        let result: (AuthorizationRef, Pipe) = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.launch(helper: helper.path, arguments: [broker.path, pid]) })
            }
        }
        authorization = result.0
        pipe = result.1

        let greeting = try await readLine()
        guard greeting == "READY" else {
            close()
            throw PrivilegedSessionError.launchFailed(greeting.isEmpty ? "il processo amministratore non è partito" : greeting)
        }
        isReady = true
    }

    /// Asks the broker to start a session whose folder is already prepared.
    func startSession(directory: URL, interface: String, vlanID: Int?, useAsPrimary: Bool) async throws {
        let command = ["START", directory.path, interface, vlanID.map(String.init) ?? "-", useAsPrimary ? "1" : "0"]
        guard command.allSatisfy({ !$0.contains(where: { $0.isWhitespace }) }) else {
            throw PrivilegedSessionError.launchFailed("percorso della sessione non valido")
        }
        let reply = try await send(command.joined(separator: " "))
        guard reply == "STARTED" else {
            throw PrivilegedSessionError.launchFailed(reply.hasPrefix("ERROR ") ? String(reply.dropFirst(6)) : reply)
        }
    }

    // MARK: Pipe

    private func send(_ line: String) async throws -> String {
        guard let pipe else { throw PrivilegedSessionError.launchFailed("processo amministratore non attivo") }
        let reply: String? = await withCheckedContinuation { continuation in
            queue.async {
                let written = fputs(line + "\n", pipe.file) >= 0 && fflush(pipe.file) == 0
                continuation.resume(returning: written ? Self.readLine(from: pipe) : nil)
            }
        }
        guard let reply else {
            isReady = false
            close()
            throw PrivilegedSessionError.launchFailed("il processo amministratore è terminato")
        }
        return reply
    }

    private func readLine() async throws -> String {
        guard let pipe else { return "" }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.readLine(from: pipe) ?? "") }
        }
    }

    private nonisolated static func readLine(from pipe: Pipe) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard fgets(&buffer, Int32(buffer.count), pipe.file) != nil else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func close() {
        if let pipe { fclose(pipe.file) }
        pipe = nil
        if let authorization { AuthorizationFree(authorization, []) }
        authorization = nil
        isReady = false
    }

    // MARK: Authorization

    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    /// AuthorizationExecuteWithPrivileges is deprecated and hidden from Swift,
    /// but it is the only way to get a root process with a private pipe
    /// without an installed, separately signed launchd daemon.
    private nonisolated static func launch(helper: String, arguments: [String]) throws -> (AuthorizationRef, Pipe) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            throw PrivilegedSessionError.launchFailed("API di autorizzazione non disponibile")
        }
        let execute = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)

        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else {
            throw PrivilegedSessionError.launchFailed("autorizzazione non disponibile")
        }
        let prompt = "ONT The Wire deve gestire le connessioni PPPoE (accesso diretto alla scheda di rete). Lo chiede una sola volta finché l’app resta aperta."
        let status = kAuthorizationRightExecute.withCString { rightName in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                prompt.withCString { promptText in
                    var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var envItem = AuthorizationItem(
                        name: promptKey, valueLength: strlen(promptText),
                        value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &right) { rightPtr in
                        withUnsafeMutablePointer(to: &envItem) { envPtr in
                            var rights = AuthorizationRights(count: 1, items: rightPtr)
                            var environment = AuthorizationEnvironment(count: 1, items: envPtr)
                            return AuthorizationCopyRights(
                                ref, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            if status == errAuthorizationCanceled { throw PrivilegedSessionError.authorizationCancelled }
            throw PrivilegedSessionError.launchFailed("autorizzazione negata (codice \(status))")
        }

        let cArgs: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pipe: UnsafeMutablePointer<FILE>?
        let launched = cArgs.withUnsafeBufferPointer { buffer in
            execute(ref, helper, [], buffer.baseAddress!, &pipe)
        }
        guard launched == errAuthorizationSuccess, let pipe else {
            AuthorizationFree(ref, [])
            throw PrivilegedSessionError.launchFailed("avvio del processo amministratore non riuscito (codice \(launched))")
        }
        return (ref, Pipe(file: pipe))
    }

    /// The pipe to the broker; only ever used on `queue`.
    private struct Pipe: @unchecked Sendable {
        let file: UnsafeMutablePointer<FILE>
    }
}
