import Foundation
@testable import SheetMusicCore
import Testing

@Suite("TiePlanner")
struct TiePlannerTests {
    @Test func `finds a same-pitch tie target in the next chord`() {
        let score = EditingFixtures.twoConsecutiveC4Chords()

        let target = TiePlanner.tieTarget(for: EditingFixtures.noteID(element: 1), in: score)

        #expect(target == EditingFixtures.noteID(element: 2))
    }

    @Test func `a different pitch in the next chord is not a tie target`() {
        let score = EditingFixtures.c4ThenD4Chords()

        let target = TiePlanner.tieTarget(for: EditingFixtures.noteID(element: 1), in: score)

        #expect(target == nil)
    }

    @Test func `finds a same-pitch tie target across the barline`() {
        let score = EditingFixtures.c4AcrossBarline()

        let target = TiePlanner.tieTarget(for: EditingFixtures.noteID(element: 4), in: score)

        let expected = NoteID(
            staff: EditingFixtures.staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        )
        #expect(target == expected)
    }

    // MARK: - tieChain

    @Test func `an untied note is a chain of one`() {
        let score = EditingFixtures.chordAtIndex1()

        let chain = TiePlanner.tieChain(containing: EditingFixtures.noteID(element: 1), in: score)

        #expect(chain == [EditingFixtures.noteID(element: 1)])
    }

    @Test func `a chain is walked in both directions from any member`() {
        let score = EditingFixtures.tiedC4Chain(length: 3)
        let expected = [1, 2, 3].map { EditingFixtures.noteID(element: $0) }

        for member in expected {
            #expect(TiePlanner.tieChain(containing: member, in: score) == expected)
        }
    }

    @Test func `a same-pitch neighbour that is not tied stays out of the chain`() {
        let score = EditingFixtures.twoConsecutiveC4Chords()

        let chain = TiePlanner.tieChain(containing: EditingFixtures.noteID(element: 1), in: score)

        #expect(chain == [EditingFixtures.noteID(element: 1)])
    }

    @Test func `a chain crosses the barline`() throws {
        var score = EditingFixtures.c4AcrossBarline()
        let head = EditingFixtures.noteID(element: 4)
        let tail = EditingFixtures.noteID(measure: 1, element: 0)
        _ = try SetTie(from: head, to: tail, sourceTieForward: 1, targetTieBack: 1).apply(to: &score)

        #expect(TiePlanner.tieChain(containing: tail, in: score) == [head, tail])
    }

    @Test func `within a chord, the nth tie out pairs with the nth tie in`() {
        // Two C4+E4 chords where only the UPPER note is tied. Matching by in-chord index would wrongly pair the
        // lower notes; the pairing is by rank among the notes that actually carry a tie.
        var score = EditingFixtures.fourQuarterRests()
        for element in 1 ... 2 {
            let lower = Note(pitch: 60, tpc: 14)
            var upper = Note(pitch: 64, tpc: 18)
            upper.tieForward = element == 1 ? 1 : nil
            upper.tieBack = element == 2 ? 1 : nil
            score[VoiceElementID(
                staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element,
            )] = .chord(Chord(duration: .quarter, notes: [lower, upper]))
        }

        let upperHead = EditingFixtures.noteID(element: 1, noteIndex: 1)
        let upperTail = EditingFixtures.noteID(element: 2, noteIndex: 1)
        #expect(TiePlanner.tieChain(containing: upperHead, in: score) == [upperHead, upperTail])
        #expect(
            TiePlanner.tieChain(containing: EditingFixtures.noteID(element: 1), in: score)
                == [EditingFixtures.noteID(element: 1)],
        )
    }
}
