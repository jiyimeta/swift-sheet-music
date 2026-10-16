import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML octave shifts")
struct MusicXMLOctaveShiftTests {
    private typealias F = DirectionFixtures

    private static func shift(_ type: String, size: Int = 8, extra: String = "") -> String {
        F.direction("<octave-shift type=\"\(type)\" size=\"\(size)\" number=\"1\"/>", extra)
    }

    private static func c5(_ count: Int) -> String {
        (0 ..< count).map { _ in F.quarter("C", octave: 5) }.joined()
    }

    @Test("notes under an 8va are written an octave lower, and the stop's offset is ignored (Review Focus 4)")
    func notesUnderAnEightVaAreWrittenLower() throws {
        let c5 = F.quarter("C", octave: 5)
        let body = c5 + Self.shift("down") + c5 + c5 + Self.shift("stop", extra: "<offset>240</offset>") + c5
        let voice = try F.voice(F.score(measures: [body]))
        #expect(F.pitches(in: voice) == [72, 60, 60, 72])
        let spanners = F.spanners(in: voice)
        #expect(spanners.map(\.tick) == [480, 1440])
        #expect(spanners.first?.spanner.kind == .ottava)
        #expect(spanners.first?.spanner.ottava?.subtype == .eightVA)
        #expect(spanners.first?.spanner.placement == nil)
        #expect(spanners.last?.spanner.isEndMarker == true)
    }

    private static let shapeRows: [(String, Int, Spanner.OttavaPayload.Subtype, Int)] = [
        ("down", 15, .fifteenMA, -24), ("up", 8, .eightVB, 12), ("up", 15, .fifteenMB, 24),
        ("down", 22, .twentyTwoMA, -36),
    ]

    @Test("the type and size choose the ottava and the written pitch", arguments: shapeRows)
    func shapes(type: String, size: Int, subtype: Spanner.OttavaPayload.Subtype, semitones: Int) throws {
        let body = F.quarter("C", octave: 5) + Self.shift(type, size: size) + F.quarter("C", octave: 5)
            + Self.shift("stop", size: size) + F.quarter("C", octave: 5) + F.quarter("C", octave: 5)
        let voice = try F.voice(F.score(measures: [body]))
        #expect(F.pitches(in: voice) == [72, 72 + semitones, 72, 72])
        #expect(F.spanners(in: voice).first?.spanner.ottava?.subtype == subtype)
    }

    @Test("a size other than 8, 15 or 22 makes nothing")
    func unknownSize() throws {
        let body = F.quarter("C", octave: 5) + Self.shift("down", size: 9) + Self.c5(3) + Self.shift("stop", size: 9)
        let voice = try F.voice(F.score(measures: [body]))
        #expect(F.pitches(in: voice) == [72, 72, 72, 72])
        #expect(F.spanners(in: voice).isEmpty)
    }

    @Test("a shift runs across bars until its stop")
    func acrossBars() throws {
        let score = try F.score(measures: [
            Self.shift("down") + Self.c5(4),
            Self.c5(2) + Self.shift("stop") + Self.c5(2),
        ])
        #expect(F.pitches(in: F.voice(score, measure: 0)) == [60, 60, 60, 60])
        #expect(F.pitches(in: F.voice(score, measure: 1)) == [60, 60, 72, 72])
        let begin = F.spanners(in: F.voice(score, measure: 0)).first?.spanner
        #expect(begin?.nextMeasuresOffset == 1)
        #expect(begin?.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
    }

    @Test("an explicit placement that is not the styled side is kept")
    func placement() throws {
        let start = F.direction(
            "<octave-shift type=\"down\" size=\"8\" number=\"1\"/>", attributes: "placement=\"below\"",
        )
        let body = start + Self.c5(2) + Self.shift("stop") + Self.c5(2)
        let begin = try F.spanners(in: F.voice(F.score(measures: [body]))).first?.spanner
        #expect(begin?.placement == .below)
    }

    /// Every note of each chord, in voice order.
    private static func chordPitches(in voice: Voice) -> [[Int]] {
        voice.elements.values.compactMap { element -> [Int]? in
            guard case let .chord(chord) = element else { return nil }
            return chord.notes.map(\.pitch)
        }
    }

    /// Every note-on of the rendered score, sorted by tick then pitch.
    private static func noteOns(_ score: Score) throws -> [Int] {
        let midi = try MidiRenderer.render(score: score)
        let ons = midi.tracks.flatMap(\.events).compactMap { event -> (tick: Int, pitch: Int)? in
            guard case let .noteOn(_, pitch, _) = event.event else { return nil }
            return (event.tick, pitch)
        }
        return ons.sorted { $0.tick == $1.tick ? $0.pitch < $1.pitch : $0.tick < $1.tick }.map(\.pitch)
    }

    @Test("a <chord/> tone takes the shift at its chord's start, not at the clock past it (P2:7183)")
    func chordTone() throws {
        let e5 = F.quarter("E", octave: 5, extra: "<chord/>")
        let body = Self.shift("down") + Self.c5(2) + e5 + Self.shift("stop") + Self.c5(2)
        let voice = try F.voice(F.score(measures: [body]))
        #expect(Self.chordPitches(in: voice) == [[60], [60, 64], [72], [72]])
    }

    @Test("a shift on staff 1 leaves staff 2's notes as written")
    func otherStaff() throws {
        let staff2 = F.whole("C", octave: 3, voice: 5, staff: 2)
        let body = Self.shift("down") + Self.c5(4) + Self.shift("stop") + "<backup><duration>1920</duration></backup>"
            + staff2
        let score = try F.score(measures: [body], staves: 2)
        #expect(F.pitches(in: F.voice(score, staff: 0)) == [60, 60, 60, 60])
        #expect(F.pitches(in: F.voice(score, staff: 1)) == [48])
    }

    @Test("a <backup> voice under an 8va is written lower and still sounds as the file says")
    func backupVoiceSounds() throws {
        let voice2 = F.half("A", voice: 2) + F.half("A", voice: 2)
        let body = Self.shift("down") + Self.c5(4) + Self.shift("stop") + "<backup><duration>1920</duration></backup>"
            + voice2
        let score = try F.score(measures: [body])
        #expect(F.pitches(in: F.voice(score, voice: 0)) == [60, 60, 60, 60])
        #expect(F.pitches(in: F.voice(score, voice: 1)) == [57, 57])
        // The ottava sits in voice 0 only; playback applies it to the whole staff, so voice 2 sounds A4 (69).
        #expect(try Self.noteOns(score) == [69, 72, 72, 69, 72, 72])
    }
}
