@testable import SheetMusicCore
import Testing

@Suite("SetSwing")
struct SetSwingTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    /// MuseScore's own "Swing" cell: eighths at 60%.
    private static let swung = SetSwing.Settings(text: "Swing", unit: .eighth, ratio: 60)
    /// And its "Straight" cell, which is the same element with the unit off — the ratio rides along unchanged so
    /// flipping back to swing does not lose it.
    private static let straight = SetSwing.Settings(text: "Straight", unit: .off, ratio: 60)

    @Test("a swing directive is written, read back, edited in place and removed")
    func writesReadsEditsRemoves() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let anchor = Self.slot(2, 0)

        #expect(session.apply(.setSwing(anchor: anchor, settings: Self.swung, isSystemText: true)))
        #expect(SetSwing.current(at: anchor, isSystemText: true, in: session.score) == Self.swung)

        // An edit of the same beat mutates the directive that is there rather than stacking a second one.
        let shuffled = SetSwing.Settings(text: "Shuffle", unit: .sixteenth, ratio: 67)
        #expect(session.apply(.setSwing(anchor: anchor, settings: shuffled, isSystemText: true)))
        #expect(SetSwing.current(at: anchor, isSystemText: true, in: session.score) == shuffled)

        #expect(session.apply(.setSwing(anchor: anchor, settings: nil, isSystemText: true)))
        #expect(SetSwing.current(at: anchor, isSystemText: true, in: session.score) == nil)
    }

    @Test("straight is the same element with the unit off")
    func straightIsTheSameElement() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let anchor = Self.slot(2, 0)

        #expect(session.apply(.setSwing(anchor: anchor, settings: Self.swung, isSystemText: true)))
        #expect(session.apply(.setSwing(anchor: anchor, settings: Self.straight, isSystemText: true)))

        let current = SetSwing.current(at: anchor, isSystemText: true, in: session.score)
        #expect(current?.unit == .off)
        // The ratio survives the trip through "straight", so turning swing back on restores what it was.
        #expect(current?.ratio == 60)
    }

    @Test("restating what the beat already says plans to nothing, and an empty label is refused")
    func restatingAndEmptyLabel() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let anchor = Self.slot(2, 0)

        // Removing from a beat that carries nothing is `.nothingToApply`, not `.targetNotFound`: the planner
        // compares what is there against what was asked for, and "no directive" already reads that way. The
        // command's own `.targetNotFound` is what a removal reaching the engine anyway would raise.
        #expect(!session.apply(.setSwing(anchor: anchor, settings: nil, isSystemText: true)))
        #expect(session.lastRefusal?.reason == .nothingToApply)

        #expect(session.apply(.setSwing(anchor: anchor, settings: Self.swung, isSystemText: true)))
        #expect(!session.apply(.setSwing(anchor: anchor, settings: Self.swung, isSystemText: true)))
        #expect(session.lastRefusal?.reason == .nothingToApply)

        // Trimmed before the comparison, like a staff text's label.
        let padded = SetSwing.Settings(text: "  Swing  ", unit: .eighth, ratio: 60)
        #expect(!session.apply(.setSwing(anchor: anchor, settings: padded, isSystemText: true)))

        let blank = SetSwing.Settings(text: "   ", unit: .eighth, ratio: 60)
        #expect(!session.apply(.setSwing(anchor: anchor, settings: blank, isSystemText: true)))
        #expect(session.lastRefusal?.reason == .emptyStaffText)
    }

    @Test("a staff-bound directive and a system one at the same beat are two marks")
    func staffAndSystemAreSeparate() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let anchor = Self.slot(2, 0)
        let staffBound = SetSwing.Settings(text: "Swing", unit: .eighth, ratio: 60, isSystemText: false)

        #expect(session.apply(.setSwing(anchor: anchor, settings: Self.swung, isSystemText: true)))
        #expect(session.apply(.setSwing(anchor: anchor, settings: staffBound, isSystemText: false)))

        #expect(SetSwing.current(at: anchor, isSystemText: true, in: session.score) == Self.swung)
        #expect(SetSwing.current(at: anchor, isSystemText: false, in: session.score) == staffBound)
    }

    @Test("undo restores the lane exactly")
    func undoRestoresTheLane() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        let anchor = Self.slot(2, 0)

        #expect(session.apply(.setSwing(anchor: anchor, settings: Self.swung, isSystemText: true)))
        #expect(session.undo())
        #expect(session.score == before)
    }
}
