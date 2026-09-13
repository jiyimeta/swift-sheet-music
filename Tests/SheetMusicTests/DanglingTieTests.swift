import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// A `<Spanner type="Tie">` whose `<next>` has no answering `<prev>` is a
/// half-spanner: MuseScore's connector reader pairs the two sides by
/// `<location>` and discards whichever side is left over, so the tie does
/// not exist in the score it loads. Our decoder used to read the tie
/// sides positionally — `<next>` present means `tieForward = 1` — and so
/// kept a tie MuseScore had thrown away.
///
/// The cost lands in playback, not engraving. `LayoutEngine.resolveTies`
/// pairs the ends itself and draws nothing for an unmatched one, but
/// `MidiRenderer` trusts the flag: `tieForward` suppresses the note-off,
/// and `resolveUnisonOverlap` then closes the never-released note-on at
/// its own tick — a zero-length note. The whole tie chain leading into it
/// goes silent.
///
/// Reproduces 泡沫サタデーナイト.mscz, where three voices carry a tie
/// across a key change into a dotted half that also holds a stale
/// outgoing tie pointing at the quarter rest behind it. MuseScore's own
/// MIDI export sounds those notes for the full 1/8 + 3/4; ours emitted a
/// note-on and note-off at the same tick.
struct DanglingTieTests {
    /// Bar 1 holds an eighth on beat 4½ tying across the barline; bar 2
    /// opens with a key change and the dotted half receiving that tie.
    /// The dotted half additionally carries the stale outgoing tie whose
    /// `<next>` names its own bar's quarter rest.
    /// Beats 1-4: three rests, then the eighth that ties across the barline.
    private static let barOne = """
            <Measure>
              <voice>
                <Rest><durationType>half</durationType></Rest>
                <Rest><durationType>quarter</durationType></Rest>
                <Rest><durationType>eighth</durationType></Rest>
                <Chord>
                  <durationType>eighth</durationType>
                  <Note>
                    <Spanner type="Tie">
                      <Tie/>
                      <next>
                        <location>
                          <measures>1</measures>
                          <fractions>-7/8</fractions>
                        </location>
                      </next>
                    </Spanner>
                    <pitch>69</pitch>
                    <tpc>17</tpc>
                  </Note>
                </Chord>
              </voice>
            </Measure>
    """

    /// The key change, the dotted half receiving the tie, and — when
    /// `dangling` — the stale outgoing tie naming this bar's quarter rest.
    private static func barTwo(dangling: Bool) -> String {
        let staleTie = dangling ? """
                      <Spanner type="Tie">
                        <Tie/>
                        <next>
                          <location>
                            <fractions>3/4</fractions>
                          </location>
                        </next>
                      </Spanner>

        """ : ""
        return """
                <Measure>
                  <voice>
                    <KeySig><concertKey>3</concertKey></KeySig>
                    <Chord>
                      <dots>1</dots>
                      <durationType>half</durationType>
                      <Note>
        \(staleTie)              <Spanner type="Tie">
                          <prev>
                            <location>
                              <measures>-1</measures>
                              <fractions>7/8</fractions>
                            </location>
                          </prev>
                        </Spanner>
                        <pitch>69</pitch>
                        <tpc>17</tpc>
                      </Note>
                    </Chord>
                    <Rest><durationType>quarter</durationType></Rest>
                  </voice>
                </Measure>
        """
    }

    private static func mscx(withDanglingForwardTie dangling: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="x"><longName>X</longName></Instrument>
            </Part>
            <Staff id="1">
        \(barOne)
        \(barTwo(dangling: dangling))
            </Staff>
          </Score>
        </museScore>
        """
    }

    private static func tiedChordNote(_ score: Score) -> Note {
        let measure = score.parts[0].staves[0].measures[1]
        for element in measure.voices[0].elements.values {
            if case let .chord(chord) = element, let note = chord.notes.first {
                return note
            }
        }
        Issue.record("bar 2 has no chord")
        return Note(pitch: 0, tpc: 0)
    }

    /// The stale outgoing tie is dropped; the real incoming tie survives.
    @Test func danglingForwardTieIsDropped() throws {
        let score = try MSCXParser.parse(Data(Self.mscx(withDanglingForwardTie: true).utf8))
        let note = Self.tiedChordNote(score)
        #expect(note.tieBack != nil)
        #expect(note.tieForward == nil)
    }

    /// The tie chain sounds for its full 1/8 + 3/4 — one note-on at the
    /// eighth, one note-off at the end of the dotted half. Matches
    /// MuseScore 4.6's own MIDI export of the reporting score.
    @Test func danglingForwardTieDoesNotSilenceTheChain() throws {
        let score = try MSCXParser.parse(Data(Self.mscx(withDanglingForwardTie: true).utf8))
        let file = try MidiRenderer.render(score: score)
        let events = file.tracks.flatMap(\.events).filter {
            switch $0.event {
            case let .noteOn(_, pitch, _), let .noteOff(_, pitch, _): pitch == 69
            default: false
            }
        }
        // Bar 1 is 1920 ticks; the eighth sits at 7/8 of it.
        let onTick = 1680
        let offTick = onTick + 240 + 1440 - 1
        #expect(events.count == 2)
        #expect(events.first?.tick == onTick)
        #expect(events.last?.tick == offTick)
    }

    /// The same file without the stale spanner must decode and sound
    /// identically — the prune may not touch a tie that has its partner.
    @Test func pairedTieIsUntouched() throws {
        let score = try MSCXParser.parse(Data(Self.mscx(withDanglingForwardTie: false).utf8))
        let note = Self.tiedChordNote(score)
        #expect(note.tieBack != nil)
        #expect(note.tieForward == nil)

        let file = try MidiRenderer.render(score: score)
        let events = file.tracks.flatMap(\.events).filter {
            switch $0.event {
            case let .noteOn(_, pitch, _), let .noteOff(_, pitch, _): pitch == 69
            default: false
            }
        }
        #expect(events.count == 2)
        #expect(events.first?.tick == 1680)
        #expect(events.last?.tick == 1680 + 240 + 1440 - 1)
    }

    /// A tie between two adjacent chords keeps both of its sides.
    @Test func ordinaryTieSurvivesThePrune() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="x"><longName>X</longName></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Chord>
                    <durationType>half</durationType>
                    <Note>
                      <Spanner type="Tie">
                        <Tie/>
                        <next><location><fractions>1/2</fractions></location></next>
                      </Spanner>
                      <pitch>60</pitch>
                      <tpc>14</tpc>
                    </Note>
                  </Chord>
                  <Chord>
                    <durationType>half</durationType>
                    <Note>
                      <Spanner type="Tie">
                        <prev><location><fractions>-1/2</fractions></location></prev>
                      </Spanner>
                      <pitch>60</pitch>
                      <tpc>14</tpc>
                    </Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements.values
        guard case let .chord(first) = elements[0], case let .chord(second) = elements[1] else {
            Issue.record("expected two chords")
            return
        }
        #expect(first.notes[0].tieForward != nil)
        #expect(second.notes[0].tieBack != nil)
    }
}
