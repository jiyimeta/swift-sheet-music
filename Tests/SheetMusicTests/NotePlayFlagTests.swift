import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// A note carrying `<play>0</play>` (MuseScore's per-note "do not
/// sound" flag, used e.g. for muted drum noteheads) must be parsed,
/// suppressed in MIDI, and round-tripped on export.
/// C++: `Note::play()` gates `CompatMidiRender::collectNote`.
struct NotePlayFlagTests {
    @Test func decodesPlayFlag() throws {
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
                    <durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                    <Note><pitch>67</pitch><tpc>15</tpc><play>0</play></Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let chord = try #require(firstChord(in: score))
        #expect(chord.notes.count == 2)
        #expect(chord.notes[0].play == true)
        #expect(chord.notes[1].play == false)
    }

    @Test func mutedNoteProducesNoMidi() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Note(pitch: 60, tpc: 14),
                Note(pitch: 67, tpc: 15, play: false),
            ]),
        )
        let score = Score(division: 480, parts: [Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
        )])
        let file = try MidiRenderer.render(score: score)
        let onPitches = file.tracks.flatMap(\.events).compactMap { ev -> Int? in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return pitch }
            return nil
        }
        #expect(onPitches.contains(60))
        #expect(!onPitches.contains(67))
    }

    @Test func encodesPlayFlagOnRoundTrip() {
        let note = Note(pitch: 67, tpc: 15, play: false)
        let xml = note.encode()
        let playNode = xml.children.first { $0.name == "play" }
        #expect(playNode?.text == "0")

        let playingXML = Note(pitch: 60, tpc: 14).encode()
        #expect(!playingXML.children.contains { $0.name == "play" })
    }

    private func firstChord(in score: Score) -> Chord? {
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            if case let .chord(chord) = element, !chord.notes.isEmpty {
                                return chord
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
}
