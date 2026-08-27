import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("Note fret/string")
struct NoteFretStringTests {
    @Test("prebend fixture decodes <fret> and <string>")
    func decodeFretString() throws {
        let data = try MSCXFixtureLoader.mscxData("guitarbend_prebend")
        let score = try MSCXParser.parse(data)
        // The fixture's first two chords — the `<appoggiatura/>` grace and
        // its parent — both carry `<fret>0</fret><string>3</string>`
        // (`guitarbend_prebend.mscx:154-155` and `:178-179`), so this holds
        // whichever of the two the walk reaches first.
        let note = try #require(firstNote(of: score))
        #expect(note.fret == 0)
        #expect(note.string == 3)
    }

    /// Deliberately compares only the tablature positions rather than whole
    /// `Score` equality: the encoder drops an implicit C-major `<KeySig>` at
    /// the head of a staff to match MuseScore Studio's writer convention
    /// (`MSCXEncoder+Measure.swift:26`), and this fixture has exactly that
    /// (`guitarbend_prebend.mscx:121-124`), so a whole-`Score` round-trip can
    /// never compare equal here for reasons unrelated to fret/string.
    @Test("fret/string survive a model round-trip")
    func roundTrip() throws {
        let data = try MSCXFixtureLoader.mscxData("guitarbend_prebend")
        let original = try MSCXParser.parse(data)
        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)

        let before = tablature(of: original)
        let after = tablature(of: roundTripped)
        // Guard against passing vacuously if the walk ever stops finding notes.
        #expect(before.count == 9)
        #expect(before.allSatisfy { $0 == Position(fret: 0, string: 3) })
        #expect(after == before)
    }

    private struct Position: Equatable {
        var fret: Int?
        var string: Int?
    }

    private func tablature(of score: Score) -> [Position] {
        allNotes(of: score).map { Position(fret: $0.fret, string: $0.string) }
    }

    private func allNotes(of score: Score) -> [Note] {
        var result: [Note] = []
        for (_, staff) in score.allStaves {
            for measure in staff.measures {
                for voice in measure.voices {
                    for element in voice.elements {
                        guard case let .chord(chord) = element else { continue }
                        // Grace notes carry `<fret>`/`<string>` too, and this
                        // fixture's bends hang off appoggiaturas.
                        for grace in chord.graceNotesBefore {
                            result.append(contentsOf: grace.notes)
                        }
                        result.append(contentsOf: chord.notes)
                        for grace in chord.graceNotesAfter {
                            result.append(contentsOf: grace.notes)
                        }
                    }
                }
            }
        }
        return result
    }

    private func firstNote(of score: Score) -> Note? {
        allNotes(of: score).first
    }
}
