import Foundation
import Observation

/// Imported 3CX templates, kept as copies of the original files in
/// ~/Library/Application Support/ONT The Wire/SIP templates. Templates hold no
/// credentials, so unlike the rest of the app they survive a relaunch.
@MainActor
@Observable
public final class SIPTemplateStore {
    public private(set) var templates: [SIPTemplate] = []

    @ObservationIgnored private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ONT The Wire/SIP templates", isDirectory: true)
        reload()
    }

    public func template(id: String?) -> SIPTemplate? {
        templates.first { $0.id == id }
    }

    /// Validates and copies a template file. A template with the same name
    /// replaces the previous one.
    @discardableResult
    public func importTemplate(from url: URL) throws -> SIPTemplate {
        let data = try Data(contentsOf: url)
        let parsed = try SIPTemplate.parse(data, fileName: "")
        let fileName = Self.fileName(for: parsed.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        reload()
        var stored = parsed
        stored.fileName = fileName
        return stored
    }

    public func remove(_ template: SIPTemplate) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(template.fileName))
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        templates = files
            .filter { $0.pathExtension.lowercased() == "xml" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? SIPTemplate.parse(data, fileName: url.lastPathComponent)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated static func fileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "template" : cleaned) + ".xml"
    }
}
