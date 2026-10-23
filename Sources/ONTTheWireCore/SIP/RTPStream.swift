import Foundation
import os

/// Audio for a test call (RFC 3550): two beeps, then an echo of whatever the
/// other side says, so whoever answers hears the line working both ways.
/// One packet every 20 ms; the remote address follows the first packet
/// received (symmetric RTP, needed behind NAT).
final class RTPStream: @unchecked Sendable {
    struct Stats: Equatable, Sendable {
        var sent = 0
        var received = 0
        /// Highest received level, dBFS.
        var peakLevel: Double?
        var source: String?
    }

    static let frameSamples = 160
    /// Beep, pause, beep (in 20 ms frames), then echo.
    private static let tonePattern: [Bool] = Array(repeating: true, count: 20) + Array(repeating: false, count: 10)
        + Array(repeating: true, count: 20) + Array(repeating: false, count: 10)
    private static let maxEchoBacklog = 25

    let localPort: UInt16

    private let queue = DispatchQueue(label: "it.ontthewire.sip.rtp")
    private var socket: UDPSocket!
    private var timer: DispatchSourceTimer?
    private let statsLock = OSAllocatedUnfairLock(initialState: Stats())

    // Confined to `queue`.
    private var remote: UDPEndpoint?
    private var latched = false
    private var codec: RTPCodec = .pcma
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private let ssrc = UInt32.random(in: 0...UInt32.max)
    private var frameIndex = 0
    private var echo: [Data] = []
    private var phase = 0.0

    init(interface: String?) throws {
        // Even ports in the usual RTP range.
        let ports = (0..<8).map { _ in UInt16(2 * Int.random(in: 20_000...29_999)) }
        var receive: ((Data, UDPEndpoint) -> Void)?
        socket = try UDPSocket(interface: interface, preferredPorts: ports, queue: queue) { data, from in
            receive?(data, from)
        }
        localPort = socket.localPort
        receive = { [weak self] data, from in self?.receive(data, from: from) }
    }

    var stats: Stats { statsLock.withLock { $0 } }

    func start(remote: UDPEndpoint, codec: RTPCodec) {
        queue.async { [weak self] in
            guard let self else { return }
            self.remote = remote
            self.codec = codec
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Updates the remote media after a re-INVITE or a late answer.
    func update(remote: UDPEndpoint, codec: RTPCodec) {
        queue.async {
            if !self.latched { self.remote = remote }
            self.codec = codec
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            socket.close()
        }
    }

    private func tick() {
        guard let remote else { return }
        let payload: Data
        if frameIndex < Self.tonePattern.count {
            payload = Self.tonePattern[frameIndex] ? toneFrame() : silenceFrame()
            if frameIndex == Self.tonePattern.count - 1 { echo.removeAll() }
        } else {
            payload = echo.isEmpty ? silenceFrame() : echo.removeFirst()
        }
        frameIndex += 1

        var packet = Data(capacity: 12 + payload.count)
        packet.append(0x80)
        packet.append(UInt8(codec.payloadType) | (frameIndex == 1 ? 0x80 : 0))  // marker on the first packet
        packet.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian, Array.init))
        packet.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        packet.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        packet.append(payload)
        socket.send(packet, to: remote)
        sequence &+= 1
        timestamp &+= UInt32(payload.count)
        statsLock.withLock { $0.sent += 1 }
    }

    private func receive(_ data: Data, from source: UDPEndpoint) {
        guard let (payloadType, payload) = Self.parse(data) else { return }
        // Symmetric RTP: answer where the audio comes from.
        if !latched {
            latched = true
            remote = source
        }
        guard payloadType == codec.payloadType, !payload.isEmpty else { return }
        echo.append(payload)
        if echo.count > Self.maxEchoBacklog { echo.removeFirst(echo.count - Self.maxEchoBacklog) }

        let peak = payload.reduce(0) { max($0, abs(Int(G711.decode($1, codec)))) }
        let level = peak > 0 ? 20 * log10(Double(peak) / 32768) : -96
        statsLock.withLock { stats in
            stats.received += 1
            stats.peakLevel = max(stats.peakLevel ?? -96, level)
            stats.source = source.description
        }
    }

    /// 1 kHz at about -12 dBFS.
    private func toneFrame() -> Data {
        var frame = Data(count: Self.frameSamples)
        for i in 0..<Self.frameSamples {
            frame[i] = G711.encode(Int16(8000 * sin(phase)), codec)
            phase += 2 * .pi * 1000 / 8000
        }
        phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        return frame
    }

    private func silenceFrame() -> Data {
        Data(repeating: G711.encode(0, codec), count: Self.frameSamples)
    }

    /// Payload type and payload of an RTP packet, skipping CSRCs, header
    /// extension and padding.
    static func parse(_ data: Data) -> (Int, Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        var offset = 12 + Int(bytes[0] & 0x0F) * 4
        if bytes[0] & 0x10 != 0 {
            guard bytes.count >= offset + 4 else { return nil }
            offset += 4 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) * 4
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0, let padding = bytes.last { end -= Int(padding) }
        guard offset <= end else { return nil }
        return (Int(bytes[1] & 0x7F), Data(bytes[offset..<end]))
    }
}
