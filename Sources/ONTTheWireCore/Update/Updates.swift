// Automatic updates from GitHub Releases. A release carries
// ONT-The-Wire-<version>.zip (the app bundle, made by scripts/make-release.sh)
// and ONT-The-Wire-<version>.zip.sig, an Ed25519 signature of the zip. Only
// packages signed with the key whose public half is embedded below are
// installed. See docs/SICUREZZA.md.

import CryptoKit
import Darwin
import Foundation

public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    /// Accepts "1.2.3" and "v1.2.3"; pre-release tags ("1.2.3-beta") are rejected.
    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var c: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            c.append(n)
        }
        components = c
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        let pa = a.components + Array(repeating: 0, count: n - a.components.count)
        let pb = b.components + Array(repeating: 0, count: n - b.components.count)
        return pa.lexicographicallyPrecedes(pb)
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    public let archiveURL: URL
    public let archiveSize: Int64
    public let signatureURL: URL
}

public enum UpdateError: Error, Equatable, Sendable {
    case network(String)
    case malformedRelease(String)
    case missingAsset(String)
    case badSignature
    case unexpectedBundle(String)
    case translocated
    case notWritable(String)
    case installFailed(String)

    /// Text for the user, in Italian like the rest of the app.
    public var message: String {
        switch self {
        case .badSignature:
            "L’aggiornamento scaricato non è firmato con la chiave di ONT The Wire ed è stato scartato."
        case .translocated:
            "macOS sta eseguendo l’app da una posizione temporanea. Spostala in Applicazioni, aprila da lì e riprova."
        case .notWritable:
            "L’app non può sostituirsi nella cartella in cui si trova. Spostala in una cartella scrivibile, come Applicazioni."
        case .missingAsset, .malformedRelease, .unexpectedBundle:
            "L’ultima release su GitHub non contiene un pacchetto di aggiornamento valido."
        case .network:
            "GitHub non è raggiungibile. Controlla la connessione a Internet."
        case .installFailed:
            "Non è stato possibile installare l’aggiornamento."
        }
    }
}

public enum UpdateFeed {
    public static let repository = "Abi0ne/ONT-the-Wire"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// Public half of the release signing key (scripts/update-signing.swift).
    public static let publicKey = "D/6mYPkPSaU4NXbfmX70k0t6Yky4HRihpExBYgVEdnc="
    /// Upper bound for the downloaded package, as a guard against a bogus release.
    public static let maxArchiveSize: Int64 = 100 << 20

    public static func archiveName(_ v: AppVersion) -> String { "ONT-The-Wire-\(v).zip" }

    /// Parse the GitHub "latest release" JSON. Drafts and pre-releases are ignored
    /// by that endpoint; they are rejected here as well.
    public static func parseLatestRelease(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: URL
        }
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let r: Release
        do {
            r = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateError.malformedRelease("JSON non valido")
        }
        guard r.draft != true, r.prerelease != true else { throw UpdateError.malformedRelease("non è una release definitiva") }
        guard let version = AppVersion(r.tag_name) else { throw UpdateError.malformedRelease("tag \(r.tag_name)") }
        let name = archiveName(version)
        guard let zip = r.assets.first(where: { $0.name == name }) else { throw UpdateError.missingAsset(name) }
        guard let sig = r.assets.first(where: { $0.name == name + ".sig" }) else { throw UpdateError.missingAsset(name + ".sig") }
        guard zip.size > 0, zip.size <= maxArchiveSize else { throw UpdateError.malformedRelease("dimensione \(zip.size)") }
        for url in [zip.browser_download_url, sig.browser_download_url] where url.scheme != "https" {
            throw UpdateError.malformedRelease("URL non sicuro")
        }
        return ReleaseInfo(version: version, notes: r.body ?? "", pageURL: r.html_url,
                           archiveURL: zip.browser_download_url, archiveSize: zip.size,
                           signatureURL: sig.browser_download_url)
    }

    /// `signature` is the base64 text of the .sig asset.
    public static func verify(archive: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: publicKey), let sig = Data(base64Encoded: text),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { return false }
        return key.isValidSignature(sig, for: archive)
    }
}

/// Unpacks a verified package next to the installed app and swaps the bundles
/// once the app has quit.
public enum UpdateInstaller {
    public static let bundleName = "ONT The Wire.app"

    /// The bundle that will be replaced, after checking it can be.
    public static func installationTarget(_ bundle: URL = Bundle.main.bundleURL) throws -> URL {
        let path = bundle.resolvingSymlinksInPath().path
        guard !path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
        guard bundle.pathExtension == "app" else { throw UpdateError.notWritable(path) }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent), FileManager.default.isWritableFile(atPath: path) else {
            throw UpdateError.notWritable(parent)
        }
        return bundle
    }

    /// Extract the zip into a staging directory on the same volume as `target`
    /// and check the bundle inside. Returns the staged app.
    public static func stage(archive: URL, version: AppVersion, target: URL, bundleID: String) throws -> URL {
        let fm = FileManager.default
        let staging: URL
        do {
            staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        } catch {
            throw UpdateError.installFailed("cartella temporanea: \(error.localizedDescription)")
        }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        let app = staging.appendingPathComponent(bundleName)
        try validateBundle(app, version: version, bundleID: bundleID)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    public static func validateBundle(_ app: URL, version: AppVersion, bundleID: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.unexpectedBundle("Info.plist mancante") }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.unexpectedBundle("identificativo del bundle")
        }
        guard let v = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init), v == version else {
            throw UpdateError.unexpectedBundle("la versione non corrisponde alla release")
        }
        guard let exe = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path)
        else { throw UpdateError.unexpectedBundle("eseguibile mancante") }
    }

    /// Start a detached helper that waits for this process to exit, swaps the
    /// bundles (restoring the old one on failure) and optionally relaunches.
    public static func scheduleReplacement(staged: URL, target: URL, relaunch: Bool) throws {
        let script = """
        pid="$1"; new="$2"; dest="$3"; relaunch="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        old="$dest.previous-$$"
        mv "$dest" "$old" || exit 1
        if mv "$new" "$dest"; then
            rm -rf "$old" "$(dirname "$new")"
        else
            mv "$old" "$dest"; exit 1
        fi
        [ "$relaunch" = 1 ] && /usr/bin/open "$dest"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "ontthewire-update", String(getpid()), staged.path, target.path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw UpdateError.installFailed("helper: \(error.localizedDescription)")
        }
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw UpdateError.installFailed("\(tool): \(error.localizedDescription)")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.installFailed("\((tool as NSString).lastPathComponent) è uscito con \(p.terminationStatus)")
        }
    }
}
