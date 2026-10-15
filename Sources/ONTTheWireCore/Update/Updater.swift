import Foundation
import Observation

/// Checks GitHub at every launch. A newer release is downloaded, its signature
/// verified and the bundle unpacked next to the installed app; the swap happens
/// when the app quits (or right away, with a relaunch, if the user asks).
@MainActor
@Observable
public final class Updater {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(ReleaseInfo)
        case ready(ReleaseInfo)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    /// Show the update alert: an update is ready, or the result of a manual check.
    public var showAlert = false

    public let currentVersion: String
    private let log: LogStore
    @ObservationIgnored private var staged: (app: URL, target: URL)?

    public init(log: LogStore, currentVersion: String? = nil) {
        self.log = log
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
    }

    public var isWorking: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    public var readyRelease: ReleaseInfo? {
        if case .ready(let release) = phase { return release }
        return nil
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "ONT-The-Wire"]
        return URLSession(configuration: c)
    }()

    /// `userInitiated` decides whether "up to date" and errors get an alert;
    /// a ready update always does.
    public func check(userInitiated: Bool) async {
        guard !isWorking else { return }
        if readyRelease != nil {
            showAlert = true
            return
        }
        // `swift run` has no bundle to replace.
        guard Bundle.main.bundleURL.pathExtension == "app", let current = AppVersion(currentVersion) else {
            if userInitiated {
                phase = .failed("Gli aggiornamenti non sono disponibili per le build di sviluppo.")
                showAlert = true
            }
            return
        }
        phase = .checking
        do {
            var request = URLRequest(url: UpdateFeed.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                finishUpToDate("nessuna release pubblicata", userInitiated: userInitiated)
                return
            }
            guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
            let release = try UpdateFeed.parseLatestRelease(data)
            guard release.version > current else {
                finishUpToDate("ultima release \(release.version)", userInitiated: userInitiated)
                return
            }
            log.info("Aggiornamento disponibile: versione \(release.version)")
            await download(release, userInitiated: userInitiated)
        } catch {
            failed(error, userInitiated: userInitiated)
        }
    }

    /// Swap the bundles after quitting and relaunch the new version. The
    /// caller terminates the app (which closes any PPPoE session first).
    public func scheduleInstall(relaunch: Bool) -> Bool {
        guard let staged else { return false }
        do {
            try UpdateInstaller.scheduleReplacement(staged: staged.app, target: staged.target, relaunch: relaunch)
            self.staged = nil
            log.info(relaunch ? "Installazione dell’aggiornamento e riavvio" : "L’aggiornamento verrà installato alla chiusura")
            return true
        } catch {
            failed(error, userInitiated: relaunch)
            return false
        }
    }

    private func download(_ release: ReleaseInfo, userInitiated: Bool) async {
        phase = .downloading(release)
        do {
            let target = try UpdateInstaller.installationTarget()
            let (signature, sigResponse) = try await Self.session.data(from: release.signatureURL)
            try Self.requireOK(sigResponse)
            let (tmp, zipResponse) = try await Self.session.download(from: release.archiveURL)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try Self.requireOK(zipResponse)
            let archive = try Data(contentsOf: tmp)
            guard archive.count <= UpdateFeed.maxArchiveSize else { throw UpdateError.malformedRelease("archivio troppo grande") }
            guard UpdateFeed.verify(archive: archive, signature: signature) else { throw UpdateError.badSignature }
            log.info("Aggiornamento \(release.version) scaricato, firma valida")
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let app = try await Task.detached {
                try UpdateInstaller.stage(archive: tmp, version: release.version, target: target, bundleID: bundleID)
            }.value
            staged = (app, target)
            phase = .ready(release)
            showAlert = true
        } catch {
            failed(error, userInitiated: userInitiated)
        }
    }

    private func finishUpToDate(_ detail: String, userInitiated: Bool) {
        log.info("ONT The Wire \(currentVersion) è aggiornata (\(detail))")
        phase = .upToDate
        showAlert = userInitiated
    }

    private func failed(_ error: Error, userInitiated: Bool) {
        let message = (error as? UpdateError)?.message ?? UpdateError.network("").message
        log.warning("Controllo aggiornamenti non riuscito: \(error)")
        phase = .failed(message)
        showAlert = userInitiated
    }

    private static func requireOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.network("HTTP \(status)") }
    }
}
