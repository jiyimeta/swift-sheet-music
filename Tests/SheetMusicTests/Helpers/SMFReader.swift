import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX

/// Reads SMF (format 0/1) bytes back into a `MidiFile` for testing.
/// Supports running status, all event kinds the renderer emits, and ignores SysEx.
enum SMFReader {
    enum ReadError: Error { case malformed(String) }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func read(_ data: Data) throws -> MidiFile {
        var cursor = 0
        func require(_ n: Int) throws {
            guard cursor + n <= data.count else { throw ReadError.malformed("truncated at \(cursor)") }
        }
        func readUInt8() throws -> UInt8 { try require(1); defer { cursor += 1 }; return data[cursor] }
        func readUInt16BE() throws -> UInt16 {
            try require(2); defer { cursor += 2 }
            return (UInt16(data[cursor]) << 8) | UInt16(data[cursor + 1])
        }
        func readUInt32BE() throws -> UInt32 {
            try require(4); defer { cursor += 4 }
            return (UInt32(data[cursor]) << 24) | (UInt32(data[cursor + 1]) << 16)
                | (UInt32(data[cursor + 2]) << 8) | UInt32(data[cursor + 3])
        }
        func readBytes(_ n: Int) throws -> Data {
            try require(n); defer { cursor += n }
            return data.subdata(in: cursor ..< (cursor + n))
        }
        func readVLQ() throws -> Int {
            var v = 0
            for _ in 0 ..< 4 {
                let b = try readUInt8()
                v = (v << 7) | Int(b & 0x7F)
                if b & 0x80 == 0 { return v }
            }
            throw ReadError.malformed("VLQ too long")
        }

        guard try readBytes(4) == Data("MThd".utf8) else { throw ReadError.malformed("missing MThd") }
        let headerLen = try readUInt32BE()
        guard headerLen == 6 else { throw ReadError.malformed("unexpected MThd length \(headerLen)") }
        let format = try Int(readUInt16BE())
        let ntracks = try Int(readUInt16BE())
        let division = try Int(readUInt16BE())

        var tracks: [MidiTrack] = []
        for _ in 0 ..< ntracks {
            guard try readBytes(4) == Data("MTrk".utf8) else { throw ReadError.malformed("missing MTrk") }
            let bodyLen = try Int(readUInt32BE())
            let bodyEnd = cursor + bodyLen
            var events: [TimedMidiEvent] = []
            var tick = 0
            var runningStatus: UInt8 = 0
            while cursor < bodyEnd {
                let delta = try readVLQ()
                tick += delta
                var status = try readUInt8()
                if status < 0x80 {
                    cursor -= 1
                    status = runningStatus
                } else if status < 0xF0 {
                    runningStatus = status
                }
                let channel = Int(status & 0x0F)
                switch status & 0xF0 {
                case 0x80:
                    let pitch = try Int(readUInt8()), vel = try Int(readUInt8())
                    let event = MidiEvent.noteOff(channel: channel, pitch: pitch, velocity: vel)
                    events.append(TimedMidiEvent(tick: tick, event: event))
                case 0x90:
                    let pitch = try Int(readUInt8()), vel = try Int(readUInt8())
                    let event: MidiEvent = vel == 0
                        ? .noteOff(channel: channel, pitch: pitch, velocity: 0)
                        : .noteOn(channel: channel, pitch: pitch, velocity: vel)
                    events.append(TimedMidiEvent(tick: tick, event: event))
                case 0xA0:
                    _ = try readUInt8(); _ = try readUInt8()
                case 0xB0:
                    let cc = try Int(readUInt8()), value = try Int(readUInt8())
                    let event = MidiEvent.controlChange(channel: channel, controller: cc, value: value)
                    events.append(TimedMidiEvent(tick: tick, event: event))
                case 0xC0:
                    let prog = try Int(readUInt8())
                    let event = MidiEvent.programChange(channel: channel, program: prog)
                    events.append(TimedMidiEvent(tick: tick, event: event))
                case 0xD0:
                    _ = try readUInt8()
                case 0xE0:
                    _ = try readUInt8(); _ = try readUInt8()
                default:
                    if status == 0xFF {
                        let metaType = try readUInt8()
                        let len = try readVLQ()
                        let payload = try readBytes(len)
                        try parseMeta(metaType: metaType, payload: payload, len: len, tick: tick, into: &events)
                    } else if status == 0xF0 || status == 0xF7 {
                        let len = try readVLQ()
                        cursor += len
                    } else {
                        throw ReadError.malformed("unknown status 0x\(String(status, radix: 16)) at \(cursor)")
                    }
                }
            }
            tracks.append(MidiTrack(events: events))
        }

        return MidiFile(division: division, format: format, tracks: tracks)
    }

    private static func parseMeta(
        metaType: UInt8,
        payload: Data,
        len: Int,
        tick: Int,
        into events: inout [TimedMidiEvent]
    ) throws {
        let start = payload.startIndex
        switch metaType {
        case 0x03:
            let name = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            events.append(TimedMidiEvent(tick: tick, event: .meta(.trackName(name))))
        case 0x21 where len == 1:
            events.append(TimedMidiEvent(tick: tick, event: .meta(.portChange(port: Int(payload[start])))))
        case 0x2F:
            events.append(TimedMidiEvent(tick: tick, event: .endOfTrack))
        case 0x51 where len == 3:
            let micros = (Int(payload[start]) << 16)
                | (Int(payload[start + 1]) << 8)
                | Int(payload[start + 2])
            events.append(TimedMidiEvent(tick: tick, event: .meta(.tempo(microsecondsPerQuarter: micros))))
        case 0x58 where len == 4:
            let n = Int(payload[start])
            let d = 1 << Int(payload[start + 1])
            let cc = Int(payload[start + 2])
            let t = Int(payload[start + 3])
            let meta = MetaEvent.timeSignature(
                numerator: n, denominator: d, clocksPerClick: cc, thirtySecondsPerQuarter: t
            )
            events.append(TimedMidiEvent(tick: tick, event: .meta(meta)))
        case 0x59 where len == 2:
            let sf = Int(Int8(bitPattern: payload[start]))
            let isMinor = payload[start + 1] != 0
            events.append(TimedMidiEvent(tick: tick, event: .meta(.keySignature(sharpsFlats: sf, isMinor: isMinor))))
        default:
            break
        }
    }
}
