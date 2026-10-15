import Foundation
import Observation
import os

public struct LogEntry: Identifiable, Equatable, Sendable {
    public enum Level: Sendable { case info, warning, error }

    public let id = UUID()
    public let date: Date
    public let level: Level
    public let message: String
}

/// In-app log shown in the UI and mirrored to the unified log.
///
/// Callers must never pass credentials. Messages are composed by the app from
/// fixed strings, interface names, VLAN IDs, status codes and IP addresses.
@MainActor
@Observable
public final class LogStore {
    public private(set) var entries: [LogEntry] = []

    private let limit: Int
    private let logger = Logger(subsystem: "it.ontthewire.app", category: "connection")

    public init(limit: Int = 500) {
        self.limit = limit
    }

    public func info(_ message: String) { append(.info, message) }
    public func warning(_ message: String) { append(.warning, message) }
    public func error(_ message: String) { append(.error, message) }

    public func clear() { entries.removeAll() }

    public var plainText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return entries.map { entry in
            let tag = switch entry.level {
            case .info: "INFO"
            case .warning: "WARN"
            case .error: "ERR "
            }
            return "\(formatter.string(from: entry.date)) \(tag) \(entry.message)"
        }.joined(separator: "\n")
    }

    private func append(_ level: LogEntry.Level, _ message: String) {
        entries.append(LogEntry(date: Date(), level: level, message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}
