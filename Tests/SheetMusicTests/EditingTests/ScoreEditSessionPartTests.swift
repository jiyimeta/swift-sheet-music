@testable import SheetMusicCore
import Testing

/// The host-facing half of the part commands: `.removePart` / `.movePart` driven through `ScoreEditSession`, and
/// the part-index mapping a host reads afterwards to follow its per-part preferences across the edit.
@Suite("Part intents and the session's part-index mapping")
struct ScoreEditSessionPartTests {
    /// Two parts — flute (one staff) and piano (grand staff) — with ids "1" and "2", so a mapping assertion is
    /// reading real identity rather than array positions that happen to line up.
    private func duet() -> Score {
        Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")], gmProgram: 73),
                .init(
                    instrumentID: "piano", longName: "Piano",
                    staves: [.init(clefType: "G"), .init(clefType: "F")],
                ),
            ],
            measureCount: 3,
        ))
    }

    private static let clarinet = BlankScoreTemplate.PartPlan(
        instrumentID: "clarinet-bb", longName: "Clarinet in B♭",
        staves: [.init(clefType: "G")],
        transposeDiatonic: -1, transposeChromatic: -2, gmProgram: 71,
    )

    // MARK: - .removePart

    @Test("removing a part drops its column, and undo puts the score back exactly")
    func removePartDropsColumnAndUndoRestoresIt() {
        let original = duet()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.removePart(at: 0)))
        #expect(session.score.parts.count == 1)
        #expect(session.score.parts[0].instrument.id == "piano")
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("removing a score's only part is refused for its own reason")
    func removingLastPartIsRefused() {
        let score = Score.blank(BlankScoreTemplate(
            title: "t", parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 2,
        ))
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.removePart(at: 0)))
        #expect(session.lastRefusal?.reason == .cannotRemoveLastPart)
        #expect(session.score == score)
    }

    @Test("an out-of-range part index is refused as a missing target", arguments: [-1, 2])
    func removePartOutOfRangeIsRefused(index: Int) {
        let session = ScoreEditSession(score: duet())
        #expect(!session.apply(.removePart(at: index)))
        guard case .targetNotFound? = session.lastRefusal?.reason else {
            Issue.record("expected .targetNotFound, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
    }

    /// A four-part SATB under one bracket: dropping an inner part shrinks the span over the survivors, and undo has
    /// to bring the span back byte-for-byte — the re-anchor pass is not reversible by arithmetic, so the inverse
    /// carries the pre-image whole.
    @Test("a cross-part bracket shrinks over the removed staff and comes back on undo")
    func removedPartBracketsRestoreOnOtherStaves() {
        let original = Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [
                .init(instrumentID: "s", staves: [.init(clefType: "G")]),
                .init(instrumentID: "a", staves: [.init(clefType: "G")]),
                .init(instrumentID: "t", staves: [.init(clefType: "G8vb")]),
                .init(instrumentID: "b", staves: [.init(clefType: "F")]),
            ],
            bracketGroups: [0 ..< 4],
            measureCount: 2,
        ))
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.removePart(at: 1)))
        #expect(session.score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 3)])
        #expect(session.undo())
        #expect(session.score == original)
        #expect(session.score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 4)])
    }

    // MARK: - .movePart

    @Test("a move reorders the parts, and undo puts them back")
    func movePartReordersAndUndoRestores() {
        let original = duet()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.movePart(from: 0, to: 1)))
        #expect(session.score.parts[1].instrument.id == original.parts[0].instrument.id)
        #expect(session.undo())
        #expect(session.score == original)
    }

    /// A move onto its own index would otherwise push an undo entry that restores the score to itself — a dead ⌘Z.
    @Test("a move onto its own index resolves to nothing to apply")
    func movePartOntoItselfIsNothingToApply() {
        let score = duet()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.movePart(from: 1, to: 1)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    @Test("an out-of-range move index is refused as a missing target", arguments: [-1, 2])
    func movePartOutOfRangeIsRefused(index: Int) {
        let session = ScoreEditSession(score: duet())
        #expect(!session.apply(.movePart(from: index, to: 0)))
        guard case .targetNotFound? = session.lastRefusal?.reason else {
            Issue.record("expected .targetNotFound, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
        #expect(!session.apply(.movePart(from: 0, to: index)))
        guard case .targetNotFound? = session.lastRefusal?.reason else {
            Issue.record("expected .targetNotFound, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
    }

    // MARK: - partIndexMapping

    @Test("a fresh session maps every part onto itself")
    func mappingStartsAsIdentity() {
        let session = ScoreEditSession(score: duet())
        #expect(session.partIndexMapping == [0: 0, 1: 1])
        #expect(session.isPartMappingIdentity)
    }

    @Test("the mapping composes across several ops, and follows an undo back")
    func cumulativeMappingComposesAcrossOpsAndUndo() {
        let session = ScoreEditSession(score: duet())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 0)))
        #expect(session.apply(.removePart(at: 2)))
        // The flute was part 0 and is now part 1; the piano was part 1 and is gone.
        #expect(session.partIndexMapping == [0: 1, 1: nil])
        #expect(!session.isPartMappingIdentity)
        #expect(session.undo())
        #expect(session.partIndexMapping == [0: 1, 1: 2])
        session.consumePartIndexMapping()
        #expect(session.isPartMappingIdentity)
        #expect(session.partIndexMapping == [0: 0, 1: 1, 2: 2])
    }

    @Test("a move shows up in the mapping as the permutation it is")
    func mappingReportsAMove() {
        let session = ScoreEditSession(score: duet())
        #expect(session.apply(.movePart(from: 0, to: 1)))
        #expect(session.partIndexMapping == [0: 1, 1: 0])
        #expect(!session.isPartMappingIdentity)
    }

    /// A part appended at the END moves nothing, so there is nothing for a host to migrate — the mapping stays
    /// identity even though the score grew.
    @Test("appending a part leaves the mapping identity")
    func mappingIgnoresAnAppendedPart() {
        let session = ScoreEditSession(score: duet())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 2)))
        #expect(session.isPartMappingIdentity)
    }

    /// Ids in a malformed file need not be unique, and `firstIndex(of:)` cannot tell two parts sharing one apart —
    /// so the mapping refuses to guess and reports identity, which a host reads as "nothing to migrate".
    @Test("duplicate baseline part ids report identity rather than a wrong answer")
    func mappingRefusesToGuessWithDuplicateIDs() {
        var score = duet()
        score.parts[1].id = score.parts[0].id
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.movePart(from: 0, to: 1)))
        #expect(session.partIndexMapping == [0: 0, 1: 1])
        #expect(session.isPartMappingIdentity)
    }
}
