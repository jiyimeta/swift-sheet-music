import Foundation
import SheetMusicCore

/// Serialises a `MidiFile` into SMF bytes (format 0/1).
public enum MidiWriter {
    /// Encode the given `MidiFile` into a complete SMF byte stream
    /// (`MThd` header + one `MTrk` chunk per track).
    public static func write(_ file: MidiFile) throws -> Data {
        var encoder = BinaryEncoder()

        encoder.append(Data("MThd".utf8))
        encoder.appendUInt32BE(6)
        encoder.appendUInt16BE(UInt16(file.format))
        encoder.appendUInt16BE(UInt16(file.tracks.count))
        encoder.appendUInt16BE(UInt16(file.division))

        for track in file.tracks {
            let body = try encodeTrack(track)
            encoder.append(Data("MTrk".utf8))
            encoder.appendUInt32BE(UInt32(body.count))
            encoder.append(body)
        }

        return encoder.data
    }

    private static func encodeTrack(_ track: MidiTrack) throws -> Data {
        var encoder = BinaryEncoder()

        var lastTick = 0
        var sawEndOfTrack = false

        for timed in track.events {
            let delta = timed.tick - lastTick
            precondition(delta >= 0, "Track events must be sorted by tick")
            encoder.append(VariableLengthQuantity.encode(delta))
            try encodeEvent(timed.event, into: &encoder)
            if case .endOfTrack = timed.event { sawEndOfTrack = true }
            lastTick = timed.tick
        }

        if !sawEndOfTrack {
            encoder.append(VariableLengthQuantity.encode(0))
            try encodeEvent(.endOfTrack, into: &encoder)
        }

        return encoder.data
    }

    private static func encodeEvent(_ event: MidiEvent, into encoder: inout BinaryEncoder) throws {
        switch event {
        case let .noteOn(ch, pitch, vel):
            encoder.appendUInt8(0x90 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(pitch & 0x7F))
            encoder.appendUInt8(UInt8(vel & 0x7F))
        case let .noteOff(ch, pitch, vel):
            encoder.appendUInt8(0x80 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(pitch & 0x7F))
            encoder.appendUInt8(UInt8(vel & 0x7F))
        case let .controlChange(ch, cc, value):
            encoder.appendUInt8(0xB0 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(cc & 0x7F))
            encoder.appendUInt8(UInt8(value & 0x7F))
        case let .programChange(ch, program):
            encoder.appendUInt8(0xC0 | UInt8(ch & 0x0F))
            encoder.appendUInt8(UInt8(program & 0x7F))
        case let .meta(meta):
            try encodeMeta(meta, into: &encoder)
        case .endOfTrack:
            encoder.appendUInt8(0xFF)
            encoder.appendUInt8(0x2F)
            encoder.appendUInt8(0x00)
        }
    }

    private static func encodeMeta(_ meta: MetaEvent, into encoder: inout BinaryEncoder) throws {
        encoder.appendUInt8(0xFF)
        switch meta {
        case let .trackName(name):
            encoder.appendUInt8(0x03)
            let bytes = Data(name.utf8)
            encoder.append(VariableLengthQuantity.encode(bytes.count))
            encoder.append(bytes)
        case let .timeSignature(n, d, cc, t):
            encoder.appendUInt8(0x58)
            encoder.appendUInt8(0x04)
            encoder.appendUInt8(UInt8(n))
            encoder.appendUInt8(UInt8(log2Denominator(d)))
            encoder.appendUInt8(UInt8(cc))
            encoder.appendUInt8(UInt8(t))
        case let .keySignature(sf, isMinor):
            encoder.appendUInt8(0x59)
            encoder.appendUInt8(0x02)
            encoder.appendUInt8(UInt8(bitPattern: Int8(sf)))
            encoder.appendUInt8(isMinor ? 1 : 0)
        case let .tempo(micros):
            encoder.appendUInt8(0x51)
            encoder.appendUInt8(0x03)
            encoder.appendUInt8(UInt8((micros >> 16) & 0xFF))
            encoder.appendUInt8(UInt8((micros >> 8) & 0xFF))
            encoder.appendUInt8(UInt8(micros & 0xFF))
        case let .portChange(port):
            encoder.appendUInt8(0x21)
            encoder.appendUInt8(0x01)
            encoder.appendUInt8(UInt8(port & 0x7F))
        }
    }

    /// SMF time-signature denominator is encoded as a power of 2: 1→0, 2→1, 4→2, 8→3, 16→4, 32→5.
    private static func log2Denominator(_ d: Int) -> Int {
        switch d {
        case 1: return 0
        case 2: return 1
        case 4: return 2
        case 8: return 3
        case 16: return 4
        case 32: return 5
        default: return 2
        }
    }
}
