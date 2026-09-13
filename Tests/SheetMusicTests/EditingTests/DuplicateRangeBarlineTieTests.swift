@testable import SheetMusicCore
import Testing

/// Ties at the destination's own BARLINES — the case `RangeCopyVoiceRebuild.cut`'s in-measure sealing cannot
/// reach.
///
/// Repeating a whole bar is the commonest `R`, and its destination span is `[0, barLength)`: nothing precedes it
/// or follows it INSIDE the rebuilt measure, so the walk that seals an element-aligned boundary has no neighbour
/// to seal. The partner that dangles is in the bar before or the bar after. MuseScore clears both ends of a tie
/// whose note it removes (`editing/addremoveelement.cpp:203-224`, `note.cpp:1348-1356`), and a barline is not a
/// boundary it treats differently.
@Suite("DuplicateRange ties across a barline")
struct DuplicateRangeBarlineTieTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func quarter(_ pitch: Int, tieForward: Int? = nil, tieBack: Int? = nil) -> VoiceElement {
        var note = Note(pitch: pitch, tpc: 14)
        note.tieForward = tieForward
        note.tieBack = tieBack
        return .chord(Chord(duration: .quarter, notes: [note]))
    }

    /// One 4/4 bar of four quarters from `base`, optionally tied forward out of its last one or back into its
    /// first. Every other tie field stays `nil`, so only the pair under test carries one.
    private static func bar(_ base: Int, tieForwardLast: Bool = false, tieBackFirst: Bool = false) -> Measure {
        var elements = (0 ..< 4).map { Self.quarter(base + $0) }
        if tieBackFirst { elements[0] = Self.quarter(base, tieBack: 1) }
        if tieForwardLast { elements[3] = Self.quarter(base + 3, tieForward: 1) }
        return Measure(voices: [Voice(elements: elements)])
    }

    private static func score(_ measures: [Measure]) -> Score {
        var score = Score(division: 480, parts: [
            Part(
                id: "1", trackName: "Flute", instrument: Instrument(id: "flute"),
                staves: [Staff(defaultClefType: "G", measures: measures)],
            ),
        ])
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        return score
    }

    private static func chord(_ score: Score, _ measure: Int, _ index: Int) -> Chord? {
        let elements = score.parts[0].staves[0].measures[measure].voices[0].elements
        guard elements.indices.contains(index), case let .chord(chord) = elements[index] else { return nil }
        return chord
    }

    @Test("the bar before the copy loses the tie that pointed into the material the copy overwrote")
    func clearsTieForwardInThePreviousBar() throws {
        var score = Self.score([
            Self.bar(60, tieForwardLast: true),
            Self.bar(72, tieBackFirst: true),
            Self.bar(48),
        ])
        // Bar 0 repeated over bar 1: the destination span is the whole bar, so `cut` files nothing into
        // `before` and the tie leaving bar 0 can only be cleared from outside the rebuilt measure.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)))
            .apply(to: &score)
        let previous = try #require(Self.chord(score, 0, 3))
        #expect(previous.notes[0].tieForward == nil)
        // The copy's own first chord lost its `tieBack` on the way out of the source, so neither half survives.
        let copied = try #require(Self.chord(score, 1, 0))
        #expect(copied.notes[0].tieBack == nil)
    }

    @Test("the bar after the copy loses the tie that pointed back into the material the copy overwrote")
    func clearsTieBackInTheFollowingBar() throws {
        var score = Self.score([
            Self.bar(60),
            Self.bar(72, tieForwardLast: true),
            Self.bar(48, tieBackFirst: true),
        ])
        // Bar 0 repeated over bar 1, whose last chord was the partner of bar 2's first.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)))
            .apply(to: &score)
        let next = try #require(Self.chord(score, 2, 0))
        #expect(next.notes[0].tieBack == nil)
        // The copy's own last chord lost its `tieForward` on the way out of the source.
        let copied = try #require(Self.chord(score, 1, 3))
        #expect(copied.notes[0].tieForward == nil)
    }

    @Test("a tie the copy carries across its own internal barline is left alone")
    func keepsATieInsideTheCopy() throws {
        var score = Self.score([
            Self.bar(60, tieForwardLast: true),
            Self.bar(72, tieBackFirst: true),
            Self.bar(48),
            Self.bar(36),
        ])
        // Bars 0-1 repeated over bars 2-3. Bar 2's span also ends on a barline and bar 3's starts on one, but
        // both sides of that seam are the copy's own material: sealing there would cut a tie in two.
        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(1, 3)))
            .apply(to: &score)
        let head = try #require(Self.chord(score, 2, 3))
        let tail = try #require(Self.chord(score, 3, 0))
        #expect(head.notes[0].tieForward == 1)
        #expect(tail.notes[0].tieBack == 1)
    }
}
