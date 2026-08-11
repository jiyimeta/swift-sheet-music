import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// Per-note velocity overrides — MuseScore's `<velocity>` / `<veloType>`
/// on `<Note>` (`Note::userVelocity()` / `Note::veloType()`), applied at
/// render time by `Note::customizeVelocity`.
struct NoteUserVelocityTests {
    // MARK: - Model

    @Test func zeroOverrideLeavesDynamicVelocityUntouched() {
        let note = Note(pitch: 60, tpc: 14)
        #expect(note.customizedVelocity(80) == 80)
        // A `.offset` type is still inert while the value is 0 — MuseScore
        // guards on `userVelocity() != 0` before calling customizeVelocity.
        let offsetNote = Note(pitch: 60, tpc: 14, velocityType: .offset)
        #expect(offsetNote.customizedVelocity(80) == 80)
    }

    @Test func userTypeReplacesTheDynamicVelocity() {
        let note = Note(pitch: 60, tpc: 14, userVelocity: 96, velocityType: .user)
        #expect(note.customizedVelocity(80) == 96)
        #expect(note.customizedVelocity(20) == 96)
    }

    @Test func offsetTypeScalesTheDynamicVelocity() {
        let louder = Note(pitch: 60, tpc: 14, userVelocity: 25, velocityType: .offset)
        #expect(louder.customizedVelocity(80) == 100) // 80 + 80*25/100
        let quieter = Note(pitch: 60, tpc: 14, userVelocity: -50, velocityType: .offset)
        #expect(quieter.customizedVelocity(80) == 40)
    }

    @Test func resultIsClampedToAudibleMidiRange() {
        let overshoot = Note(pitch: 60, tpc: 14, userVelocity: 400, velocityType: .offset)
        #expect(overshoot.customizedVelocity(80) == 127)
        let undershoot = Note(pitch: 60, tpc: 14, userVelocity: -400, velocityType: .offset)
        #expect(undershoot.customizedVelocity(80) == 1)
    }

    // MARK: - MSCX decode

    @Test func decodesAbsoluteVelocityFromMuseScore4File() throws {
        let notes = try decodeNotes(version: "4.60", noteXML: """
        <Note><pitch>60</pitch><tpc>14</tpc><velocity>96</velocity></Note>
        <Note><pitch>67</pitch><tpc>15</tpc></Note>
        """)
        #expect(notes[0].userVelocity == 96)
        #expect(notes[0].velocityType == .user)
        #expect(notes[1].userVelocity == 0)
        #expect(notes[1].velocityType == .user)
    }

    /// MuseScore 3 defaulted `veloType` to `offset` and therefore omitted
    /// it for the offset form — a bare `<velocity>` in a 3.x file is a
    /// percentage, not a MIDI velocity.
    @Test func decodesOffsetVelocityFromMuseScore3File() throws {
        let notes = try decodeNotes(version: "3.02", noteXML: """
        <Note><pitch>60</pitch><tpc>14</tpc><velocity>-20</velocity></Note>
        """)
        #expect(notes[0].userVelocity == -20)
        #expect(notes[0].velocityType == .offset)
    }

    @Test func explicitVeloTypeOverridesTheVersionDefault() throws {
        let ms3 = try decodeNotes(version: "3.02", noteXML: """
        <Note><pitch>60</pitch><tpc>14</tpc><velocity>96</velocity><veloType>user</veloType></Note>
        """)
        #expect(ms3[0].velocityType == .user)
        let ms4 = try decodeNotes(version: "4.60", noteXML: """
        <Note><pitch>60</pitch><tpc>14</tpc><velocity>-20</velocity><veloType>offset</veloType></Note>
        """)
        #expect(ms4[0].velocityType == .offset)
    }

    /// Without an override the two generations must decode identically —
    /// otherwise every note of a 3.x score would differ from its 4.x twin
    /// on a field that has no effect.
    @Test func absentVelocityNormalizesToTheModelDefault() throws {
        for version in ["3.02", "4.60"] {
            let notes = try decodeNotes(version: version, noteXML: """
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
            """)
            #expect(notes[0].userVelocity == 0)
            #expect(notes[0].velocityType == .user)
        }
    }

    // MARK: - MSCX encode

    @Test func encodesVelocityOnlyWhenOverridden() {
        #expect(!Note(pitch: 60, tpc: 14).encode().children.contains { $0.name == "velocity" })
        let overridden = Note(pitch: 60, tpc: 14, userVelocity: 96).encode()
        #expect(overridden.children.first { $0.name == "velocity" }?.text == "96")
    }

    /// `<veloType>` is written only when it differs from the target
    /// generation's default, so a MuseScore 4 file round-trips unchanged.
    @Test func encodesVeloTypeOnlyWhenItDiffersFromTheTargetDefault() {
        let absoluteV4 = Note(pitch: 60, tpc: 14, userVelocity: 96, velocityType: .user)
            .encode(options: MSCXEncoderOptions(targetVersion: .v4))
        #expect(!absoluteV4.children.contains { $0.name == "veloType" })

        let offsetV4 = Note(pitch: 60, tpc: 14, userVelocity: -20, velocityType: .offset)
            .encode(options: MSCXEncoderOptions(targetVersion: .v4))
        #expect(offsetV4.children.first { $0.name == "veloType" }?.text == "offset")

        let offsetV3 = Note(pitch: 60, tpc: 14, userVelocity: -20, velocityType: .offset)
            .encode(options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(!offsetV3.children.contains { $0.name == "veloType" })

        let absoluteV3 = Note(pitch: 60, tpc: 14, userVelocity: 96, velocityType: .user)
            .encode(options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(absoluteV3.children.first { $0.name == "veloType" }?.text == "user")
    }

    /// MuseScore writes the two elements in different parts of the
    /// property list — `velocity` between `head` and `play`, `veloType`
    /// near the tail — rather than adjacent.
    /// C++: `Note::write` (3.6.2) `Pid` list order.
    @Test func velocityAndVeloTypeSitInMuseScoresWriteOrder() {
        let note = Note(
            pitch: 60, tpc: 14, headType: "cross", play: false,
            userVelocity: -20, velocityType: .offset,
        )
        let names = note.encode().children.map(\.name)
        let tracked = ["head", "velocity", "play", "veloType"]
        #expect(names.filter { tracked.contains($0) } == tracked)
    }

    @Test func offsetVelocitySurvivesAMuseScore3ToMuseScore4RoundTrip() throws {
        let notes = try decodeNotes(version: "3.02", noteXML: """
        <Note><pitch>60</pitch><tpc>14</tpc><velocity>-20</velocity></Note>
        """)
        let reEncoded = notes[0].encode(options: MSCXEncoderOptions(targetVersion: .v4))
        let reDecoded = try Note.decode(reEncoded)
        #expect(reDecoded.userVelocity == -20)
        #expect(reDecoded.velocityType == .offset)
    }

    // MARK: - MIDI render

    @Test func absoluteVelocityOverridesTheDynamicPerNote() throws {
        let chord = Chord(duration: .quarter, notes: ChordNotes([
            Note(pitch: 60, tpc: 14),
            Note(pitch: 67, tpc: 15, userVelocity: 20, velocityType: .user),
        ]))
        let velocities = try renderNoteOnVelocities(elements: [.chord(chord)])
        #expect(velocities[60] == MidiRenderer.defaultDynamicVelocity)
        #expect(velocities[67] == 20)
    }

    @Test func offsetVelocityIsRelativeToTheRunningDynamic() throws {
        let chord = Chord(duration: .quarter, notes: ChordNotes([
            Note(pitch: 60, tpc: 14, userVelocity: -50, velocityType: .offset),
        ]))
        // ff = 110 in MuseScore's default table; -50% → 55.
        let velocities = try renderNoteOnVelocities(elements: [
            .dynamic(Dynamic(subtype: "ff", velocity: 110)),
            .chord(chord),
        ])
        #expect(velocities[60] == 55)
    }

    @Test func graceNotesCarryTheirOwnVelocityOverride() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            graceNotesBefore: [GraceChord(
                graceType: .acciaccatura,
                duration: .eighth,
                notes: ChordNotes([
                    Note(pitch: 62, tpc: 16, userVelocity: 30, velocityType: .user),
                ]),
            )],
        )
        let velocities = try renderNoteOnVelocities(elements: [.chord(chord)])
        #expect(velocities[62] == 30)
        #expect(velocities[60] == MidiRenderer.defaultDynamicVelocity)
    }

    @Test func graceNotesAfterCarryTheirOwnVelocityOverride() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            graceNotesAfter: [GraceChord(
                graceType: .grace16after,
                duration: .sixteenth,
                notes: ChordNotes([
                    Note(pitch: 62, tpc: 16, userVelocity: 30, velocityType: .user),
                ]),
            )],
        )
        let velocities = try renderNoteOnVelocities(elements: [.chord(chord)])
        #expect(velocities[62] == 30)
    }

    @Test func arpeggiatedChordNotesKeepTheirIndividualOverrides() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Note(pitch: 60, tpc: 14, userVelocity: 20, velocityType: .user),
                Note(pitch: 67, tpc: 15, userVelocity: 110, velocityType: .user),
            ]),
            arpeggio: Arpeggio(subtype: 0),
        )
        let velocities = try renderNoteOnVelocities(elements: [.chord(chord)])
        #expect(velocities[60] == 20)
        #expect(velocities[67] == 110)
    }

    /// The sweep is one sounding gesture, so every intermediate pitch
    /// takes the start note's velocity.
    @Test func glissandoSweepInheritsTheStartNoteVelocity() throws {
        let start = Chord(duration: .quarter, notes: ChordNotes([
            Note(
                pitch: 60, tpc: 14,
                glissando: Glissando(style: .chromatic),
                userVelocity: 25, velocityType: .user,
            ),
        ]))
        let end = Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))
        let velocities = try renderNoteOnVelocities(elements: [.chord(start), .chord(end)])
        for pitch in 60 ... 63 {
            #expect(velocities[pitch] == 25)
        }
        // The target note is the following chord and keeps its own.
        #expect(velocities[64] == MidiRenderer.defaultDynamicVelocity)
    }

    @Test func singleNoteTremoloStrokesInheritTheNoteVelocity() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Note(pitch: 60, tpc: 14, userVelocity: 40, velocityType: .user),
            ]),
            tremolo: Tremolo(subtype: .r16),
        )
        let events = try renderNoteOnEvents(elements: [.chord(chord)])
        let strokes = events.filter { $0.pitch == 60 }
        #expect(strokes.count == 4) // r16 → 1 << 2 strokes
        #expect(strokes.allSatisfy { $0.velocity == 40 })
    }

    /// MuseScore renders a two-note tremolo as `NoteEvent`s on the *start*
    /// chord's notes and clears the follower's own event list, so the
    /// follower's override never reaches playback — every stroke, on
    /// either pitch, sounds at the start note's velocity.
    /// C++: `CompatMidiRender::renderTremolo`.
    @Test func twoNoteTremoloTakesEveryStrokeFromTheStartChord() throws {
        let start = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Note(pitch: 60, tpc: 14, userVelocity: 40, velocityType: .user),
            ]),
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(duration: .quarter, notes: ChordNotes([
            Note(pitch: 67, tpc: 15, userVelocity: 120, velocityType: .user),
        ]))
        let events = try renderNoteOnEvents(elements: [.chord(start), .chord(follower)])
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.velocity == 40 })
        #expect(Set(events.map(\.pitch)) == [60, 67])
    }

    // MARK: - MusicXML

    /// MusicXML's `dynamics` attribute is a percentage of the default
    /// forte level, which the spec pins at MIDI velocity 90.
    @Test func musicXMLDynamicsAttributeBecomesAnAbsoluteVelocity() throws {
        #expect(try musicXMLNoteVelocity(attribute: " dynamics=\"100\"") == 90)
        #expect(try musicXMLNoteVelocity(attribute: " dynamics=\"50\"") == 45)
        #expect(try musicXMLNoteVelocity(attribute: "") == 0)
        #expect(try musicXMLNoteVelocity(attribute: " dynamics=\"0\"") == 0)
    }

    // MARK: - Helpers

    private func decodeNotes(version: String, noteXML: String) throws -> [Note] {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="\(version)">
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
                    \(noteXML)
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        for element in score.parts[0].staves[0].measures[0].voices[0].elements {
            if case let .chord(chord) = element { return Array(chord.notes) }
        }
        return []
    }

    private func renderNoteOnEvents(
        elements: [VoiceElement],
    ) throws -> [(pitch: Int, velocity: Int)] {
        let score = Score(division: 480, parts: [Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: elements)])])],
        )])
        let file = try MidiRenderer.render(score: score)
        return file.tracks.flatMap(\.events).compactMap { event in
            guard case let .noteOn(_, pitch, velocity) = event.event, velocity > 0 else {
                return nil
            }
            return (pitch: pitch, velocity: velocity)
        }
    }

    private func renderNoteOnVelocities(elements: [VoiceElement]) throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for event in try renderNoteOnEvents(elements: elements) {
            result[event.pitch] = event.velocity
        }
        return result
    }

    private func musicXMLNoteVelocity(attribute: String) throws -> Int {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>X</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions></attributes>
              <note\(attribute)>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration><voice>1</voice><type>whole</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        for element in score.parts[0].staves[0].measures[0].voices[0].elements {
            if case let .chord(chord) = element { return chord.notes[0].userVelocity }
        }
        return 0
    }
}
