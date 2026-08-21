import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// Phase 2 — MusicXML `<glissando>` / `<slide>` import.
///
/// MusicXML spells gradual pitch transitions as a `<glissando>` (notated
/// pitch sweep, MuseScore's `.chromatic`/`.diatonic` styles) or `<slide>`
/// (smooth pitch bend, MuseScore's `.portamento` style). Both come as
/// `type="start"` on one note and `type="stop"` on a later note inside
/// `<notations>`. Our decoder retroactively attaches the resolved
/// `Glissando` to the **start** chord's first note (matching MSCX's
/// `<Note><Spanner type="Glissando">` placement). Unmatched stops are
/// silently dropped (permissive parser).
struct MusicXMLGlissandoTests {
    @Test func wavy_glissando_attaches_to_start_note_as_chromatic_wavy() throws {
        let url = try #require(TestResources.url(
            forResource: "glissando-wavy", withExtension: "musicxml",
        ))
        let score = try MusicXMLParser.parse(Data(contentsOf: url))
        let chord = try #require(firstChord(of: score))
        let note = try #require(chord.notes.first)
        #expect(note.glissando?.style == .chromatic)
        #expect(note.glissando?.visualType == .wavy)
    }

    @Test func slide_attaches_as_portamento() throws {
        let url = try #require(TestResources.url(
            forResource: "slide-portamento", withExtension: "musicxml",
        ))
        let score = try MusicXMLParser.parse(Data(contentsOf: url))
        let chord = try #require(firstChord(of: score))
        let note = try #require(chord.notes.first)
        #expect(note.glissando?.style == .portamento)
    }

    @Test func unmatched_stop_does_not_attach_or_crash() throws {
        let url = try #require(TestResources.url(
            forResource: "glissando-unmatched-stop", withExtension: "musicxml",
        ))
        let score = try MusicXMLParser.parse(Data(contentsOf: url))
        for chord in allChords(of: score) {
            for note in chord.notes {
                #expect(note.glissando == nil)
            }
        }
    }

    private func firstChord(of score: Score) -> Chord? {
        guard let staff = score.parts.first?.staves.first else { return nil }
        for element in staff.measures[0].voices[0].elements {
            if case let .chord(c) = element { return c }
        }
        return nil
    }

    private func allChords(of score: Score) -> [Chord] {
        var chords: [Chord] = []
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            if case let .chord(c) = element { chords.append(c) }
                        }
                    }
                }
            }
        }
        return chords
    }
}
