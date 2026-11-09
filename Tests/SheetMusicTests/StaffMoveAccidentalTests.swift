import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// A chord moved onto a sibling staff (`<staffMove>`) shares that staff's accidental state: MuseScore keeps one state
/// per staff a note is DRAWN on and walks every track of the part into it (`ModifyDom::cmdUpdateNotes`,
/// `rendering/score/modifydom.cpp:80-126`; `Chord::cmdUpdateNotes`, `dom/chord.cpp:1166-1190`).
@Suite("<staffMove>: accidental state per drawn staff")
struct StaffMoveAccidentalTests {
    private typealias Fixture = CrossStaffFixture

    /// An F♯4 quarter carrying its ♯ glyph, optionally moved.
    private static func fSharp(move: Int? = nil) -> String {
        let moveTag = move.map { "<staffMove>\($0)</staffMove>" } ?? ""
        return "<Chord>\(moveTag)<durationType>quarter</durationType>"
            + "<Note><Accidental><subtype>accidentalSharp</subtype></Accidental><pitch>66</pitch><tpc>20</tpc></Note>"
            + "</Chord>"
    }

    /// Bar 1: the right hand plays an F♯4 moved into the bass staff on beat 1, then its own F♯4 on beat 3; the left
    /// hand plays an F♯4 on beat 2. In C major.
    private static func score() throws -> Score {
        try Fixture.parse(Fixture.piano(
            treble: [fSharp(move: 1) + Fixture.rest() + fSharp() + Fixture.rest()],
            bass: [Fixture.rest() + fSharp() + Fixture.rest("half")],
        ))
    }

    private static func noteAccidentals(_ score: Score, staff: Int) -> [Accidental?] {
        Fixture.chords(score, staff: staff).filter { !$0.notes.isEmpty }.map { $0.notes.first?.accidental }
    }

    @Test("layout: the moved F♯ covers the bass staff's F♯ after it, and not the treble staff's own")
    func suppressionFollowsTheDrawnStaff() throws {
        let suppressed = try Self.score().suppressingRedundantAccidentals()
        // Treble: the moved F♯ is the first ♯ on the bass staff, and the treble's own F♯ is the first on the treble.
        #expect(Self.noteAccidentals(suppressed, staff: 0) == [.sharp, .sharp])
        // Bass: its F♯ on beat 2 follows the moved one on the same staff — redundant.
        #expect(Self.noteAccidentals(suppressed, staff: 1) == [nil])
    }

    @Test("without the move, each staff keeps its own state — the control the test above differs from")
    func controlWithoutMove() throws {
        let score = try Fixture.parse(Fixture.piano(
            treble: [Self.fSharp() + Fixture.rest() + Self.fSharp() + Fixture.rest()],
            bass: [Fixture.rest() + Self.fSharp() + Fixture.rest("half")],
        ))
        let suppressed = score.suppressingRedundantAccidentals()
        #expect(Self.noteAccidentals(suppressed, staff: 0) == [.sharp, nil])
        #expect(Self.noteAccidentals(suppressed, staff: 1) == [.sharp])
    }

    @Test("editing: renotation reads the drawn staff too, and gives the moved F♯ its glyph back on the bass staff")
    func renotationFollowsTheDrawnStaff() throws {
        var score = try Self.score()
        // Strip every glyph, then let renotation decide them again.
        for staff in 0 ..< 2 {
            score.parts.updateValue(at: 0) { part in
                part.staves.updateValue(at: staff) { staffValue in
                    for index in staffValue.measures[0].voices[0].elements.indices {
                        staffValue.measures[0].voices[0].elements.updateValue(at: index) { element in
                            guard case var .chord(chord) = element, !chord.notes.isEmpty else { return }
                            chord.notes.updateNote(at: 0) { $0.accidental = nil }
                            element = .chord(chord)
                        }
                    }
                }
            }
        }
        var repaired = score
        for command in MeasureAccidentals.renotationCommands(in: score, measureRange: 0 ..< 1) {
            _ = try? command.apply(to: &repaired)
        }
        #expect(Self.noteAccidentals(repaired, staff: 0) == [.sharp, .sharp])
        #expect(Self.noteAccidentals(repaired, staff: 1) == [nil])
    }
}
