import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// `w5-capo-playback`: bar 1 an active capo on fret 3 (a 4.6 file: no `<transposeMode>`), bar 2 fret 2 skipping
/// string 1, bar 3 an inactive capo, bar 4 a capo that transposes the notation only.
@Suite("Capo playback")
struct CapoPlaybackTests {
    private static let bar = 1920

    private static func pitches(_ score: Score) throws -> [[Int]] {
        let midi = try MidiRenderer.render(score: score)
        let ons = midi.tracks.flatMap(\.events).compactMap { timed -> (Int, Int)? in
            if case let .noteOn(_, pitch, _) = timed.event { (timed.tick / bar, pitch) } else { nil }
        }
        return (0 ..< 4).map { bar in ons.filter { $0.0 == bar }.map(\.1).sorted() }
    }

    @Test("an active playback capo raises every note it covers by its fret")
    func activeCapoTransposesPlayback() throws {
        let bars = try Self.pitches(AnnotationFixtures.load("w5-capo-playback"))
        #expect(bars[0] == [67])
    }

    @Test("a string the capo skips keeps its pitch")
    func ignoredStringKeepsItsPitch() throws {
        let bars = try Self.pitches(AnnotationFixtures.load("w5-capo-playback"))
        // string 1 (pitch 59) is ignored; string 3 (55) takes fret 2.
        #expect(bars[1] == [57, 59])
    }

    @Test("an inactive capo, and one that transposes the notation only, do not")
    func inactiveOrNotationOnlyCapoDoesNot() throws {
        let bars = try Self.pitches(AnnotationFixtures.load("w5-capo-playback"))
        #expect(bars[2] == [60])
        #expect(bars[3] == [62])
    }

    @Test("the capo carries into a later bar until the next capo")
    func capoCarries() throws {
        let score = try AnnotationFixtures.load("tab-annotations")
        let midi = try MidiRenderer.render(score: score)
        let pitches = midi.tracks.flatMap(\.events).compactMap { timed -> Int? in
            if case let .noteOn(_, pitch, _) = timed.event { pitch } else { nil }
        }
        // Capo 2 (active) in bar 1 carries through bar 2; bar 3's capo is inactive.
        #expect(pitches == [66, 64, 60])
    }

    @Test("a capo in one voice governs every voice of its staff")
    func capoReachesEveryVoice() throws {
        let capoVoice = Voice(elements: [
            .capo(Capo(fretPosition: 2, text: "Capo 2")),
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
        ])
        let otherVoice = Voice(elements: [
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 52, tpc: 18)]))),
        ])
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "guitar-steel"),
            staves: [Staff(lineCount: 5, measures: [Measure(voices: [capoVoice, otherVoice])])],
        )], systemMeasures: [SystemMeasure()])
        let bars = try Self.pitches(score)
        #expect(bars[0] == [54, 66])
    }

    /// A capo stands at its bar's nominal position; the walk's tick also counts the breath pause earlier in the bar.
    /// At 120 BPM a half-second breath is a beat, so read with the pause the beat-2 note would land on beat 3's capo.
    @Test("a breath earlier in the bar does not bring a later capo forward")
    func breathDoesNotShiftTheCapo() throws {
        func quarter(_ pitch: Int) -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
        }
        let voice = Voice(elements: [
            quarter(60), .breath(Breath(kind: .caesura(.normal), pause: 0.5)), quarter(62),
            .capo(Capo(fretPosition: 2, text: "Capo 2")), quarter(64), quarter(65),
        ])
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "guitar-steel"),
            staves: [Staff(lineCount: 5, measures: [Measure(voices: [voice])])],
        )], systemMeasures: [SystemMeasure()])
        let pitches = try MidiRenderer.render(score: score).tracks.flatMap(\.events).compactMap { timed -> Int? in
            if case let .noteOn(_, pitch, _) = timed.event { pitch } else { nil }
        }
        #expect(pitches == [60, 62, 66, 67])
    }

    /// MuseScore sounds a tied note once, at the pitch its head's capo gives; the tail is not retuned. A tail read at
    /// its own capo would key its note-off to another pitch and leave the head's note-on sounding.
    @Test("a note tied across a capo change keeps its head's pitch, on and off")
    func tieAcrossCapoChange() throws {
        func bar(_ capo: Capo, _ note: Note) -> Measure {
            let chord = Chord(duration: .whole, notes: ChordNotes([note]))
            return Measure(voices: [Voice(elements: [.capo(capo), .chord(chord)])])
        }
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "guitar-steel"),
            staves: [Staff(lineCount: 5, measures: [
                bar(Capo(fretPosition: 3, text: "Capo 3"), Note(pitch: 60, tpc: 14, tieForward: 1)),
                bar(Capo(fretPosition: 2, text: "Capo 2"), Note(pitch: 60, tpc: 14, tieBack: 1)),
            ])],
        )], systemMeasures: [SystemMeasure(), SystemMeasure()])
        let events = try MidiRenderer.render(score: score).tracks.flatMap(\.events)
        let notes = events.compactMap { timed -> String? in
            switch timed.event {
            case let .noteOn(_, pitch, _): "on \(pitch) @\(timed.tick)"
            case let .noteOff(_, pitch, _): "off \(pitch) @\(timed.tick)"
            default: nil
            }
        }
        // One attack, released at the tied span's end (the renderer releases a tick early).
        #expect(notes == ["on 63 @0", "off 63 @\(2 * Self.bar - 1)"])
    }

    @Test("collect and active read the staff's capos in tick order")
    func ranges() throws {
        let score = try AnnotationFixtures.load("w5-capo-playback")
        let staff = score.parts[0].staves[0]
        let points = CapoRanges.collect(staff: staff, division: score.division, tempoMap: ResolvedTempoMap())
        #expect(points.map(\.tick) == [0, Self.bar, 2 * Self.bar, 3 * Self.bar])
        #expect(CapoRanges.active(in: points, at: 0)?.fret == 3)
        #expect(CapoRanges.active(in: points, at: Self.bar)?.ignoredStrings == [1])
        #expect(CapoRanges.active(in: points, at: 2 * Self.bar) == nil)
        #expect(CapoRanges.active(in: points, at: 3 * Self.bar) == nil)
    }
}
