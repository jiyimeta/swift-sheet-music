import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiReaderTests {
    /// Build an SMF byte stream "by hand" so we don't depend on MidiWriter.
    private static func makeSMF(format: UInt16, division: UInt16, tracks: [Data]) -> Data {
        var data = Data()
        data.append(contentsOf: "MThd".utf8)
        data.append(contentsOf: [0, 0, 0, 6])
        data.append(UInt8((format >> 8) & 0xFF)); data.append(UInt8(format & 0xFF))
        data.append(UInt8((tracks.count >> 8) & 0xFF)); data.append(UInt8(tracks.count & 0xFF))
        data.append(UInt8((division >> 8) & 0xFF)); data.append(UInt8(division & 0xFF))
        for track in tracks {
            data.append(contentsOf: "MTrk".utf8)
            let n = UInt32(track.count)
            data.append(UInt8((n >> 24) & 0xFF))
            data.append(UInt8((n >> 16) & 0xFF))
            data.append(UInt8((n >> 8) & 0xFF))
            data.append(UInt8(n & 0xFF))
            data.append(track)
        }
        return data
    }

    private static var emptyTrack: Data {
        Data([0x00, 0xFF, 0x2F, 0x00])
    }

    @Test func rejectsFormat2() {
        let bytes = Self.makeSMF(format: 2, division: 480, tracks: [Self.emptyTrack])
        #expect {
            _ = try MidiReader.read(bytes)
        } throws: { error in
            guard case let SheetMusicError.unsupportedFeature(name, _) = error else { return false }
            return name == "MIDI format 2"
        }
    }

    @Test func rejectsSMPTEDivision() {
        let bytes = Self.makeSMF(format: 1, division: 0xE728, tracks: [Self.emptyTrack])
        #expect {
            _ = try MidiReader.read(bytes)
        } throws: { error in
            guard case let SheetMusicError.unsupportedFeature(name, _) = error else { return false }
            return name == "SMPTE timecode division"
        }
    }

    @Test func decodesPitchBend() throws {
        let track = Data([0x00, 0xE0, 0x40, 0x60, 0x00, 0xFF, 0x2F, 0x00])
        let bytes = Self.makeSMF(format: 0, division: 480, tracks: [track])
        let file = try MidiReader.read(bytes)
        let pitchBendValue = (0x60 << 7) | 0x40
        let expected = MidiEvent.pitchBend(channel: 0, value: pitchBendValue)
        #expect(file.tracks[0].events.contains { $0.event == expected })
    }

    @Test func rejectsTruncatedHeader() {
        let truncated = Data([0x4D, 0x54, 0x68])
        #expect(throws: SheetMusicError.self) {
            _ = try MidiReader.read(truncated)
        }
    }

    @Test func acceptsRunningStatus() throws {
        let track = Data([
            0x00, 0x90, 0x3C, 0x40,
            0x0A, 0x3E, 0x40,
            0x00, 0xFF, 0x2F, 0x00,
        ])
        let bytes = Self.makeSMF(format: 0, division: 480, tracks: [track])
        let file = try MidiReader.read(bytes)
        let onEvents = file.tracks[0].events.compactMap { ev -> Int? in
            if case let .noteOn(_, pitch, _) = ev.event { return pitch } else { return nil }
        }
        #expect(onEvents == [60, 62])
    }
}
