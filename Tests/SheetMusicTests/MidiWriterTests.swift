import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct MidiWriterTests {
    @Test func writesHeaderChunkFormat1Division480() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [TimedMidiEvent(tick: 0, event: .endOfTrack)]),
        ])
        let bytes = try MidiWriter.write(file)
        #expect(Array(bytes.prefix(4)) == Array("MThd".utf8))
        #expect(Array(bytes[4 ..< 8]) == [0x00, 0x00, 0x00, 0x06])
        #expect(Array(bytes[8 ..< 10]) == [0x00, 0x01])
        #expect(Array(bytes[10 ..< 12]) == [0x00, 0x01])
        #expect(Array(bytes[12 ..< 14]) == [0x01, 0xE0])
        #expect(Array(bytes[14 ..< 18]) == Array("MTrk".utf8))
    }

    @Test func endOfTrackIsLastEvent() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .meta(.trackName("X"))),
                TimedMidiEvent(tick: 0, event: .endOfTrack),
            ]),
        ])
        let bytes = try MidiWriter.write(file)
        let suffix = Array(bytes.suffix(4))
        #expect(suffix == [0x00, 0xFF, 0x2F, 0x00])
    }

    @Test func writesNoteOnAndOffWithChannel() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 0x3C, velocity: 0x50)),
                TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 0x3C, velocity: 0)),
                TimedMidiEvent(tick: 480, event: .endOfTrack),
            ]),
        ])
        let bytes = try MidiWriter.write(file)
        let trackBytes = Array(bytes.dropFirst(22))
        #expect(trackBytes[0] == 0x00)
        #expect(trackBytes[1] == 0x90)
        #expect(trackBytes[2] == 0x3C)
        #expect(trackBytes[3] == 0x50)
        #expect(trackBytes[4] == 0x83)
        #expect(trackBytes[5] == 0x60)
        #expect(trackBytes[6] == 0x80)
        #expect(trackBytes[7] == 0x3C)
        #expect(trackBytes[8] == 0x00)
    }

    @Test func writesMetaLyric() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .meta(.lyric("la"))),
                TimedMidiEvent(tick: 0, event: .endOfTrack),
            ]),
        ])
        let bytes = try MidiWriter.write(file)
        let trackBytes = Array(bytes.dropFirst(22))
        // 00 (delta) FF 05 (Lyric) 02 (len) 6C 61 ("la")
        #expect(Array(trackBytes.prefix(6)) == [0x00, 0xFF, 0x05, 0x02, 0x6C, 0x61])
    }

    @Test func roundTripsLyricThroughWriterAndReader() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .meta(.lyric("Twin-"))),
                TimedMidiEvent(tick: 480, event: .meta(.lyric("kle"))),
                TimedMidiEvent(tick: 480, event: .endOfTrack),
            ]),
        ])
        let bytes = try MidiWriter.write(file)
        let parsed = try MidiReader.read(bytes)
        let lyrics = parsed.tracks[0].events.compactMap { ev -> (Int, String)? in
            if case let .meta(.lyric(text)) = ev.event { return (ev.tick, text) }
            return nil
        }
        #expect(lyrics.count == 2)
        #expect(lyrics[0] == (0, "Twin-"))
        #expect(lyrics[1] == (480, "kle"))
    }

    @Test func writesMetaTempoCorrectly() throws {
        let file = MidiFile(division: 480, format: 1, tracks: [
            MidiTrack(events: [
                TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 0x07A120))),
                TimedMidiEvent(tick: 0, event: .endOfTrack),
            ]),
        ])
        let bytes = try MidiWriter.write(file)
        let trackBytes = Array(bytes.dropFirst(22))
        #expect(Array(trackBytes.prefix(7)) == [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])
    }
}
