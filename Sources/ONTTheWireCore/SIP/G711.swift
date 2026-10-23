import Foundation

/// G.711 A-law and µ-law conversion (ITU-T G.711, after the reference
/// implementation by Sun Microsystems).
enum G711 {
    private static let aLawSegmentEnds: [Int] = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]
    private static let uLawSegmentEnds: [Int] = [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]
    private static let bias = 0x84
    private static let clip = 8159

    static func encode(_ sample: Int16, _ codec: RTPCodec) -> UInt8 {
        codec == .pcma ? aLaw(sample) : uLaw(sample)
    }

    static func decode(_ byte: UInt8, _ codec: RTPCodec) -> Int16 {
        codec == .pcma ? linear(aLaw: byte) : linear(uLaw: byte)
    }

    static func aLaw(_ sample: Int16) -> UInt8 {
        var pcm = Int(sample) >> 3
        let mask: Int
        if pcm >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            pcm = -pcm - 1
        }
        guard let segment = aLawSegmentEnds.firstIndex(where: { pcm <= $0 }) else { return UInt8(0x7F ^ mask) }
        var value = segment << 4
        value |= segment < 2 ? (pcm >> 1) & 0x0F : (pcm >> segment) & 0x0F
        return UInt8(value ^ mask)
    }

    static func uLaw(_ sample: Int16) -> UInt8 {
        var pcm = Int(sample) >> 2
        let mask: Int
        if pcm < 0 {
            pcm = -pcm
            mask = 0x7F
        } else {
            mask = 0xFF
        }
        pcm = min(pcm, clip) + (bias >> 2)
        guard let segment = uLawSegmentEnds.firstIndex(where: { pcm <= $0 }) else { return UInt8(0x7F ^ mask) }
        let value = (segment << 4) | ((pcm >> (segment + 1)) & 0x0F)
        return UInt8(value ^ mask)
    }

    static func linear(aLaw byte: UInt8) -> Int16 {
        let value = Int(byte ^ 0x55)
        var t = (value & 0x0F) << 4
        let segment = (value & 0x70) >> 4
        switch segment {
        case 0: t += 8
        case 1: t += 0x108
        default: t = (t + 0x108) << (segment - 1)
        }
        return Int16(value & 0x80 != 0 ? t : -t)
    }

    static func linear(uLaw byte: UInt8) -> Int16 {
        let value = Int(~byte)
        var t = ((value & 0x0F) << 3) + bias
        t <<= (value & 0x70) >> 4
        return Int16(value & 0x80 != 0 ? bias - t : t - bias)
    }
}
