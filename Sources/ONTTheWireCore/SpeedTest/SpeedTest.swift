import Foundation
import Network
import Observation
import os

/// A public HTTP endpoint pair used for throughput tests.
public struct SpeedServer: Hashable, Sendable {
    public let name: String
    let host: String
    let downloadPath: String
    let uploadPath: String?
    /// Some servers answer 429 to many parallel connections from one address.
    var maxStreams = Int.max

    /// Endpoints meant for speed testing, close to Italy. Cloudflare answers
    /// from the nearest PoP (Milan); its download size is capped below 100 MB.
    public static let all: [SpeedServer] = [
        SpeedServer(name: "Cloudflare", host: "speed.cloudflare.com",
                    downloadPath: "/__down?bytes=99000000", uploadPath: "/__up"),
        SpeedServer(name: "Apple CDN", host: "mensura.cdn-apple.com",
                    downloadPath: "/api/v1/gm/large", uploadPath: "/api/v1/gm/slurp"),
        SpeedServer(name: "OVH", host: "proof.ovh.net",
                    downloadPath: "/files/1Gb.dat", uploadPath: nil, maxStreams: 2),
    ]

    static let latencyHost = "speed.cloudflare.com"
}

public struct SpeedTestResult: Equatable, Sendable {
    public var interface: String
    public var streams: Int
    public var servers: [String] = []
    public var pingMs: Double?
    public var jitterMs: Double?
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var downloadLoadedLatencyMs: Double?
    public var uploadLoadedLatencyMs: Double?
    /// Share of the bytes moved by each server, per direction.
    public var downloadShare: [String: Double] = [:]
    public var uploadShare: [String: Double] = [:]
    public var warnings: [String] = []
}

/// Multi-stream throughput test in the style of Ookla's Speedtest: many
/// parallel TLS connections spread over several servers, all bound to one
/// interface (the PPP link, so the PPPoE line is measured even when Wi-Fi is
/// the primary connection). Speeds are aggregated; the first seconds (TCP
/// slow start) are left out of the final figure.
@MainActor
@Observable
public final class SpeedTest {
    public enum Phase: Equatable, Sendable {
        case idle
        case latency
        case download
        case upload
        case finished
        case failed(String)
    }

    public static let streamChoices = [8, 16, 32]
    static let phaseDuration: TimeInterval = 12
    static let warmUp: TimeInterval = 2
    static let pingSamples = 10

    public var streams = 16
    public private(set) var phase: Phase = .idle
    public private(set) var result: SpeedTestResult?
    /// Aggregate speed over the last second of the running phase.
    public private(set) var liveMbps: Double?
    /// Progress of the running phase, 0...1.
    public private(set) var progress: Double = 0
    public var onFinish: ((SpeedTestResult) -> Void)?

    public var isRunning: Bool {
        switch phase {
        case .latency, .download, .upload: true
        default: false
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeStreams: [TransferStream] = []

    public init() {}

    public func start(interface: String) {
        guard !isRunning else { return }
        result = SpeedTestResult(interface: interface, streams: streams)
        liveMbps = nil
        progress = 0
        phase = .latency
        task = Task { [weak self] in await self?.run(interfaceName: interface) }
    }

    public func cancel() {
        guard isRunning else { return }
        task?.cancel()
        stopStreams()
        phase = .idle
        result = nil
        liveMbps = nil
    }

    // MARK: Phases

    private func run(interfaceName: String) async {
        guard let interface = await Self.findInterface(named: interfaceName) else {
            phase = .failed("Interfaccia \(interfaceName) non disponibile per il test.")
            return
        }

        // Idle latency: TCP handshake time, i.e. one round trip.
        var samples: [Double] = []
        for i in 0..<Self.pingSamples {
            guard !Task.isCancelled else { return }
            if let ms = await TCPPing.measure(host: SpeedServer.latencyHost, interface: interface) { samples.append(ms) }
            progress = Double(i + 1) / Double(Self.pingSamples)
        }
        guard !Task.isCancelled else { return }
        guard !samples.isEmpty else {
            phase = .failed("Nessuna risposta dai server di test: la linea non raggiunge Internet.")
            return
        }
        result?.pingMs = Self.median(samples)
        result?.jitterMs = Self.jitter(samples)

        phase = .download
        guard let download = await transfer(.download, interface: interface), !Task.isCancelled else { return }
        result?.downloadMbps = download.mbps
        result?.downloadLoadedLatencyMs = download.loadedLatency
        result?.downloadShare = download.share

        phase = .upload
        guard let upload = await transfer(.upload, interface: interface), !Task.isCancelled else { return }
        result?.uploadMbps = upload.mbps
        result?.uploadLoadedLatencyMs = upload.loadedLatency
        result?.uploadShare = upload.share

        liveMbps = nil
        phase = .finished
        if let result { onFinish?(result) }
    }

    private struct TransferOutcome {
        var mbps: Double
        var loadedLatency: Double?
        var share: [String: Double]
    }

    private func transfer(_ direction: TransferStream.Direction, interface: NWInterface) async -> TransferOutcome? {
        let servers = SpeedServer.all.filter { direction == .download || $0.uploadPath != nil }
        let counter = ByteCounter()
        let failures = FailureLog()
        activeStreams = Self.assign(streams, to: servers).map { server in
            TransferStream(server: server, direction: direction, interface: interface,
                           counter: counter, failures: failures)
        }
        activeStreams.forEach { $0.start() }
        if direction == .download { result?.servers = servers.map(\.name) }
        liveMbps = 0
        progress = 0

        // Latency under load, sampled while the streams run.
        let loaded = LatencySamples()
        let probe = Task.detached {
            while !Task.isCancelled {
                if let ms = await TCPPing.measure(host: SpeedServer.latencyHost, interface: interface) { loaded.append(ms) }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        let start = Date()
        var history: [(t: TimeInterval, bytes: UInt64)] = [(0, 0)]
        var baseline: (t: TimeInterval, bytes: UInt64)?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            let t = Date().timeIntervalSince(start)
            let bytes = counter.total
            history.append((t, bytes))
            if baseline == nil, t >= Self.warmUp { baseline = (t, bytes) }
            if let past = history.last(where: { t - $0.t >= 1 }) {
                liveMbps = Double(bytes - past.bytes) * 8 / (t - past.t) / 1e6
            }
            progress = min(t / Self.phaseDuration, 1)
            if t >= Self.phaseDuration { break }
        }
        probe.cancel()
        let end = history.last ?? (0, 0)
        stopStreams()
        guard !Task.isCancelled else { return nil }

        for message in failures.messages where !(result?.warnings.contains(message) ?? false) {
            result?.warnings.append(message)
        }
        guard end.bytes > 0, let baseline, end.t > baseline.t, end.bytes > baseline.bytes else {
            phase = .failed(failures.messages.first ?? "Nessun dato trasferito: i server di test non sono raggiungibili.")
            return nil
        }
        let perServer = counter.perServer
        let total = Double(perServer.values.reduce(0, +))
        return TransferOutcome(
            mbps: Double(end.bytes - baseline.bytes) * 8 / (end.t - baseline.t) / 1e6,
            loadedLatency: loaded.values.isEmpty ? nil : Self.median(loaded.values),
            share: total > 0 ? perServer.mapValues { Double($0) / total } : [:])
    }

    private func stopStreams() {
        activeStreams.forEach { $0.stop() }
        activeStreams = []
    }

    // MARK: Helpers

    /// Spreads `count` streams round-robin over `servers`, respecting each
    /// server's cap.
    nonisolated static func assign(_ count: Int, to servers: [SpeedServer]) -> [SpeedServer] {
        var used: [String: Int] = [:]
        var result: [SpeedServer] = []
        var index = 0
        while result.count < count {
            let candidates = servers.filter { used[$0.name, default: 0] < $0.maxStreams }
            guard !candidates.isEmpty else { break }
            let server = candidates[index % candidates.count]
            used[server.name, default: 0] += 1
            result.append(server)
            index += 1
        }
        return result
    }

    nonisolated static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Mean absolute difference between consecutive samples (as Ookla reports jitter).
    nonisolated static func jitter(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let diffs = zip(values, values.dropFirst()).map { abs($1 - $0) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    /// The Network.framework handle for a BSD interface name, e.g. "ppp0".
    nonisolated static func findInterface(named name: String) async -> NWInterface? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.availableInterfaces.first { $0.name == name })
            }
            monitor.start(queue: DispatchQueue(label: "it.ontthewire.speedtest.path"))
        }
    }
}

// MARK: - Shared counters

final class ByteCounter: Sendable {
    private let bytes = OSAllocatedUnfairLock(initialState: [String: UInt64]())

    func add(_ count: Int, for server: String) {
        bytes.withLock { $0[server, default: 0] += UInt64(count) }
    }

    var total: UInt64 { bytes.withLock { $0.values.reduce(0, +) } }
    var perServer: [String: UInt64] { bytes.withLock { $0 } }
}

final class FailureLog: Sendable {
    private let entries = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ message: String) {
        entries.withLock { if !$0.contains(message) { $0.append(message) } }
    }

    var messages: [String] { entries.withLock { $0 } }
}

final class LatencySamples: Sendable {
    private let samples = OSAllocatedUnfairLock(initialState: [Double]())
    func append(_ value: Double) { samples.withLock { $0.append(value) } }
    var values: [Double] { samples.withLock { $0 } }
}

// MARK: - TCP ping

enum TCPPing {
    /// Time to complete a TCP handshake (one round trip), in milliseconds.
    static func measure(host: String, interface: NWInterface, timeout: TimeInterval = 2) async -> Double? {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters)
        let queue = DispatchQueue(label: "it.ontthewire.speedtest.ping")
        let done = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Double?) -> Void = { value in
                let first = done.withLock { finished -> Bool in
                    defer { finished = true }
                    return !finished
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

// MARK: - One HTTP transfer stream

/// One TLS connection that downloads (or uploads) as fast as it can and
/// reconnects when the server ends the response, until stopped. All mutable
/// state is confined to its serial queue.
final class TransferStream: @unchecked Sendable {
    enum Direction { case download, upload }

    private static let uploadSize = 25_000_000
    private static let chunk: Data = {
        var data = Data(count: 256 * 1024)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        return data
    }()

    private let server: SpeedServer
    private let direction: Direction
    private let interface: NWInterface
    private let counter: ByteCounter
    private let failures: FailureLog
    private let queue = DispatchQueue(label: "it.ontthewire.speedtest.stream")

    private var connection: NWConnection?
    private var stopped = false
    private var sawStatus = false
    private var consecutiveErrors = 0
    private var remainingUpload = 0

    init(server: SpeedServer, direction: Direction, interface: NWInterface, counter: ByteCounter, failures: FailureLog) {
        self.server = server
        self.direction = direction
        self.interface = interface
        self.counter = counter
        self.failures = failures
    }

    func start() {
        queue.async { self.connect() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        parameters.requiredInterface = interface
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: 443, using: parameters)
        self.connection = connection
        sawStatus = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest(on: connection)
            case .failed(let error), .waiting(let error):
                self.retry(after: "\(self.server.name): \(error.localizedDescription)", on: connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func retry(after error: String, on connection: NWConnection) {
        connection.cancel()
        guard !stopped, connection === self.connection else { return }
        consecutiveErrors += 1
        if consecutiveErrors >= 3 {
            failures.record(error)
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { self.connect() }
    }

    private func sendRequest(on connection: NWConnection) {
        let path = direction == .download ? server.downloadPath : (server.uploadPath ?? "/")
        var head = direction == .download ? "GET \(path) HTTP/1.1\r\n" : "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(server.host)\r\nUser-Agent: ONTTheWire\r\nAccept: */*\r\nConnection: close\r\n"
        if direction == .upload {
            remainingUpload = Self.uploadSize
            head += "Content-Type: application/octet-stream\r\nContent-Length: \(Self.uploadSize)\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            if self.direction == .upload { self.sendBody(on: connection) }
            self.receive(on: connection)
        })
    }

    private func sendBody(on connection: NWConnection) {
        guard !stopped, remainingUpload > 0, connection === self.connection else { return }
        let size = min(Self.chunk.count, remainingUpload)
        let data = size == Self.chunk.count ? Self.chunk : Self.chunk.prefix(size)
        remainingUpload -= size
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !self.stopped else { return }
            self.counter.add(size, for: self.server.name)
            self.consecutiveErrors = 0
            self.sendBody(on: connection)
        })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped, connection === self.connection else { return }
            if let data, !data.isEmpty {
                if !self.sawStatus {
                    self.sawStatus = true
                    if let problem = self.statusProblem(in: data) {
                        self.failures.record(problem)
                        connection.cancel()
                        return
                    }
                }
                if self.direction == .download {
                    self.counter.add(data.count, for: self.server.name)
                    self.consecutiveErrors = 0
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                self.connect()
            } else {
                self.receive(on: connection)
            }
        }
    }

    /// Checks the HTTP status line of the first response bytes.
    private func statusProblem(in data: Data) -> String? {
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        guard let line = head.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        return (200..<300).contains(code) ? nil : "\(server.name): risposta HTTP \(code)"
    }
}
