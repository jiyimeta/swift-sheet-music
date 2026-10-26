import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// A note's `<stem>` goes where MuseScore's import puts it (`handleBeamAndStemDir`): on the chord when no beam holds
/// the note, on the beam when the note begins one. The import used to read no `<stem>`, so the layout chose every
/// direction and a MuseScore save wrote none.
@Suite("MusicXML stems")
struct MusicXMLStemTests {
    private typealias F = DirectionFixtures

    private static func eighth(_ step: String, stem: String? = nil, beam: String? = nil) -> String {
        let stemTag = stem.map { "<stem>\($0)</stem>" } ?? ""
        let beamTag = beam.map { "<beam number=\"1\">\($0)</beam>" } ?? ""
        return F.note(step, duration: 240, type: "eighth", extra: stemTag + beamTag)
    }

    private static func chords(_ score: Score) -> [Chord] {
        F.voice(score).elements.values.compactMap { element in
            if case let .chord(chord) = element { chord } else { nil }
        }
    }

    @Test("a note no beam holds sets its own chord's stem; one without <stem> sets none")
    func unbeamedNoteSetsItsChord() throws {
        let score = try F.score(measures: [
            F.quarter("C", extra: "<stem>down</stem>") + F.quarter("D", extra: "<stem>up</stem>") + F.half("E"),
        ])
        #expect(Self.chords(score).map(\.stemDirection) == [.down, .up, nil])
        #expect(Self.chords(score).allSatisfy { $0.beamStemDirection == nil })
    }

    @Test("a note that begins a beam gives the beam its direction; the beam's notes set none of their own")
    func beginningNoteSetsTheBeam() throws {
        let score = try F.score(measures: [
            Self.eighth("C", stem: "down", beam: "begin") + Self.eighth("D", stem: "down", beam: "continue")
                + Self.eighth("E", stem: "down", beam: "end") + Self.eighth("F", stem: "up") + F.half("G"),
        ])
        let chords = Self.chords(score)
        #expect(chords.map(\.beamStemDirection) == [.down, nil, nil, nil, nil])
        #expect(chords.map(\.stemDirection) == [nil, nil, nil, .up, nil])
    }

    @Test("a beam begun again before it ended, or broken by a note with no beam, loses its direction")
    func brokenBeamLosesItsDirection() throws {
        let score = try F.score(measures: [
            Self.eighth("C", stem: "down", beam: "begin") + Self.eighth("D", stem: "up", beam: "begin")
                + Self.eighth("E", stem: "up", beam: "continue") + Self.eighth("F", stem: "down")
                + F.half("G"),
        ])
        let chords = Self.chords(score)
        #expect(chords.map(\.beamStemDirection) == [nil, nil, nil, nil, nil])
        #expect(chords.map(\.stemDirection) == [nil, nil, nil, .down, nil])
    }

    @Test("a MuseScore save writes the chord's and the beam's <StemDirection>")
    func mscxSaveWritesThem() throws {
        let score = try F.score(measures: [
            Self.eighth("C", stem: "down", beam: "begin") + Self.eighth("D", stem: "down", beam: "end")
                + F.quarter("E", extra: "<stem>down</stem>") + F.half("F"),
        ])
        let reread = try MSCXParser.parse(MSCXEncoder.encode(score))
        let chords = Self.chords(reread)
        #expect(chords.map(\.beamStemDirection) == [.down, nil, nil, nil])
        #expect(chords.map(\.stemDirection) == [nil, nil, .down, nil])
    }
}
