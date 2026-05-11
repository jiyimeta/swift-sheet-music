import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Verifies that the MIDI renderer collapses tied chord sequences into a single
/// sounding note, mirroring MuseScore's `Note::playTicksFraction()`:
/// the tied chain spans from the first chord's tick to the last chord's end-tick.
struct MidiRendererTieTests {
    // MARK: - Helpers

    private static func makeScore(division: Int, chords: [Chord]) -> Score {
        let instrument = Instrument(
            id: "test",
            articulations: [InstrumentArticulation()], // gate = 100, velocity = 100
        )
        let voice = Voice(elements: chords.map { .chord($0) })
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        return Score(division: division, parts: [part])
    }

    private static func noteOns(in track: MidiTrack) -> [(tick: Int, pitch: Int)] {
        track.events.compactMap { ev in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 {
                return (ev.tick, pitch)
            }
            return nil
        }
    }

    private static func noteOffs(in track: MidiTrack) -> [(tick: Int, pitch: Int)] {
        track.events.compactMap { ev in
            if case let .noteOff(_, pitch, _) = ev.event { return (ev.tick, pitch) }
            if case let .noteOn(_, pitch, vel) = ev.event, vel == 0 { return (ev.tick, pitch) }
            return nil
        }
    }

    // MARK: - Tests

    /// The user-reported scenario: a 16th note tied forward into an eighth note at
    /// pitch 75. Expected MIDI: ONE note-on at tick 0, ONE note-off at the end of
    /// the tied chain (120 + 240 = 360 ticks from start, minus 1 for MuseScore's
    /// 1-tick trailing gap).
    @Test func sixteenthTiedToEighth_producesSingleNote() throws {
        let division = 480
        let sixteenth = Chord(
            duration: .sixteenth,
            notes: [Note(pitch: 75, tpc: 11, tieForward: 1)],
        )
        let eighth = Chord(
            duration: .eighth,
            notes: [Note(pitch: 75, tpc: 11, tieBack: 1)],
        )
        let score = Self.makeScore(division: division, chords: [sixteenth, eighth])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        let ons = Self.noteOns(in: track)
        let offs = Self.noteOffs(in: track)
        #expect(ons.count == 1)
        #expect(offs.count == 1)
        #expect(ons.first?.tick == 0)
        #expect(ons.first?.pitch == 75)
        // 16th = 120 ticks, eighth = 240 ticks. Note-off lands at 360 - 1.
        #expect(offs.first?.tick == 359)
    }

    /// Three-chord tie chain (quarter-quarter-quarter all at pitch 72): one note-on
    /// at 0, one note-off spanning three quarters.
    @Test func threeChordTieChain_producesSingleSpanningNote() throws {
        let division = 480
        let a = Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14, tieForward: 1)])
        let b = Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14, tieForward: 1, tieBack: 1)])
        let c = Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14, tieBack: 1)])
        let score = Self.makeScore(division: division, chords: [a, b, c])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        let ons = Self.noteOns(in: track)
        let offs = Self.noteOffs(in: track)
        #expect(ons.count == 1)
        #expect(offs.count == 1)
        #expect(ons.first?.tick == 0)
        #expect(offs.first?.tick == 3 * division - 1)
    }

    /// Regression guard: two adjacent chords at the same pitch but *not* tied must
    /// still produce two distinct note-on/off pairs. Prevents a naive fix from
    /// merging every same-pitch repeat.
    @Test func adjacentSamePitchWithoutTie_producesTwoNotes() throws {
        let division = 480
        let a = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let b = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let score = Self.makeScore(division: division, chords: [a, b])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        #expect(Self.noteOns(in: track).count == 2)
        #expect(Self.noteOffs(in: track).count == 2)
    }

    /// Partial-chord ties: only the upper note of a two-note chord is tied into
    /// the next chord. The lower note must still produce normal on+off events;
    /// only the tied pitch is merged across chords.
    @Test func partialChordTie_onlyMergesTiedPitch() throws {
        let division = 480
        let a = Chord(
            duration: .quarter,
            notes: [
                Note(pitch: 60, tpc: 14), // C4 — not tied
                Note(pitch: 67, tpc: 15, tieForward: 1), // G4 — tied forward
            ],
        )
        let b = Chord(
            duration: .quarter,
            notes: [
                Note(pitch: 64, tpc: 18), // E4 — unrelated
                Note(pitch: 67, tpc: 15, tieBack: 1), // G4 — tied back
            ],
        )
        let score = Self.makeScore(division: division, chords: [a, b])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        let ons = Self.noteOns(in: track)
        let offs = Self.noteOffs(in: track)
        // Pitches emitted: C4 (60), G4 (67) in chord A; E4 (64) in chord B.
        // G4 emits a single note-on/off pair that spans both chords.
        #expect(Set(ons.map(\.pitch)) == [60, 64, 67])
        #expect(ons.count(where: { $0.pitch == 67 }) == 1)
        #expect(offs.count(where: { $0.pitch == 67 }) == 1)
        // G4 off is at the end of chord B (tick 480 + 480 - 1).
        let g4Off = try #require(offs.first { $0.pitch == 67 })
        #expect(g4Off.tick == 2 * division - 1)
    }

    /// End-to-end via mscx XML parsing. This reproduces the exact fragment from
    /// the user's file: a 16th note with `<Spanner type="Tie">` (+`<next>`),
    /// followed by an eighth note with `<Spanner type="Tie">` (+`<prev>`),
    /// both at pitch 75.
    @Test func parsesUsersTiedChordPair() throws {
        let xml = """
        <voice>
          <Chord>
            <linkedMain/>
            <durationType>16th</durationType>
            <Note>
              <linkedMain/>
              <Spanner type="Tie">
                <Tie><linkedMain/></Tie>
                <next><location><fractions>1/16</fractions></location></next>
              </Spanner>
              <pitch>75</pitch>
              <tpc>11</tpc>
            </Note>
          </Chord>
          <Chord>
            <linkedMain/>
            <durationType>eighth</durationType>
            <Note>
              <linkedMain/>
              <Spanner type="Tie">
                <prev><location><fractions>-1/16</fractions></location></prev>
              </Spanner>
              <pitch>75</pitch>
              <tpc>11</tpc>
            </Note>
          </Chord>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 2)
        guard case let .chord(first) = voice.elements[0],
              case let .chord(second) = voice.elements[1]
        else {
            Issue.record("expected two chords, got \(voice.elements)")
            return
        }
        #expect(first.notes.first?.tieForward == 1)
        #expect(first.notes.first?.tieBack == nil)
        #expect(second.notes.first?.tieBack == 1)
        #expect(second.notes.first?.tieForward == nil)
    }
}
