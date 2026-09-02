@testable import SheetMusicCore
import Testing

@Suite("AdjacentElementSlot")
struct AdjacentElementSlotTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let voice0 = VoiceRef(staff: staff0, measureIndex: 0, voiceIndex: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static let dynamic = VoiceElement.dynamic(Dynamic(subtype: "p", velocity: 49))
    private static let fermata = VoiceElement.fermata(Fermata(subtype: "fermataAbove"))
    private static let breath = VoiceElement.breath(Breath(kind: .breathMark(.comma)))
    private static let chord = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))

    /// `[ts, dynamic, fermata, C4, breath, r, r, r]` — a chord wearing two attachments and a breath.
    private static func dressedScore() -> Score {
        var score = EditingFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices[0] = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            dynamic, fermata, chord, breath,
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        return score
    }

    private static func elements(_ score: Score) -> [VoiceElement] {
        score.parts[0].staves[0].measures[0].voices[0].elements
    }

    @Test("the run before a chord spans its attachments and signatures; the run after it spans breaths")
    func runs() {
        let elements = Self.elements(Self.dressedScore())
        #expect(AdjacentElementSlot.run(.before, of: 3, in: elements) == 0 ..< 3)
        #expect(AdjacentElementSlot.run(.after, of: 3, in: elements) == 4 ..< 5)
        #expect(AdjacentElementSlot.run(.before, of: 5, in: elements) == 5 ..< 5)
        #expect(AdjacentElementSlot.run(.after, of: 5, in: elements) == 6 ..< 6)
    }

    @Test("find picks the matching element out of the run, and nothing outside it")
    func find() {
        let score = Self.dressedScore()
        let isFermata: (VoiceElement) -> Bool = { if case .fermata = $0 { true } else { false } }
        let isBreath: (VoiceElement) -> Bool = { if case .breath = $0 { true } else { false } }
        #expect(AdjacentElementSlot.find(.before, of: Self.slot(3), in: score, where: isFermata) == 2)
        #expect(AdjacentElementSlot.find(.after, of: Self.slot(3), in: score, where: isBreath) == 4)
        #expect(AdjacentElementSlot.find(.before, of: Self.slot(5), in: score, where: isFermata) == nil)
        // A non-timed anchor has no run.
        #expect(AdjacentElementSlot.find(.before, of: Self.slot(1), in: score, where: isFermata) == nil)
        #expect(AdjacentElementSlot.find(.before, of: Self.slot(9), in: score, where: isFermata) == nil)
    }

    @Test("insert lands nearest the chord, and its inverse restores the indices exactly")
    func insertAndUndo() throws {
        var score = EditingFixtures.chordAtIndex1() // [ts, C4, r, r, r]
        let before = score
        let insert = try #require(AdjacentElementSlot.inserting(
            Self.dynamic, at: AdjacentElementSlot.insertionIndex(.before, of: 1), in: Self.voice0, of: score,
        ))
        let inverse = try insert.apply(to: &score)
        #expect(Self.elements(score)[1] == Self.dynamic)
        #expect(Self.elements(score)[2] == Self.chord)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("a tuplet straddling the insertion point keeps its start and grows its end")
    func tupletStraddle() throws {
        var score = EditingFixtures.fourQuarterRests()
        _ = try CreateTuplet(at: Self.slot(1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        // [ts, m, m, m, r, r, r] with the triplet at 1...3.
        let middle = try #require(AdjacentElementSlot.inserting(Self.fermata, at: 2, in: Self.voice0, of: score))
        #expect(middle.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 4)])
        let first = try #require(AdjacentElementSlot.inserting(Self.fermata, at: 1, in: Self.voice0, of: score))
        #expect(first.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)])
        // At the endIndex itself the mark still lands INSIDE the tuplet — before its last member — so the end
        // grows. One past it (`4`) is outside, and the tuplet is left alone.
        let last = try #require(AdjacentElementSlot.inserting(Self.fermata, at: 3, in: Self.voice0, of: score))
        #expect(last.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 4)])
        let after = try #require(AdjacentElementSlot.inserting(Self.fermata, at: 4, in: Self.voice0, of: score))
        #expect(after.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)])
    }

    @Test("remove drops one element and shifts the tuplets after it back")
    func removeRemapsTuplets() throws {
        var score = EditingFixtures.fourQuarterRests()
        _ = try CreateTuplet(at: Self.slot(2), actualNotes: 3, normalNotes: 2).apply(to: &score)
        // [ts, r, m, m, m, r, r] with the triplet at 2...4; put a dynamic at 1 and take it away again.
        _ = try #require(AdjacentElementSlot.inserting(Self.dynamic, at: 1, in: Self.voice0, of: score))
            .apply(to: &score)
        let removal = try #require(AdjacentElementSlot.removing(at: 1, in: Self.voice0, of: score))
        #expect(removal.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 2, endIndex: 4)])
        #expect(removal.elements.count == 7)
        #expect(AdjacentElementSlot.removing(at: 9, in: Self.voice0, of: score) == nil)
    }

    @Test("replace is a plain ReplaceVoiceElement at the index")
    func replace() throws {
        var score = Self.dressedScore()
        let loud = VoiceElement.dynamic(Dynamic(subtype: "ff", velocity: 112))
        let inverse = try AdjacentElementSlot.replacing(loud, at: 1, in: Self.voice0).apply(to: &score)
        #expect(Self.elements(score)[1] == loud)
        _ = try inverse.apply(to: &score)
        #expect(Self.elements(score)[1] == Self.dynamic)
    }
}
