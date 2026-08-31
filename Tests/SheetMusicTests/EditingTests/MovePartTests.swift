@testable import SheetMusicCore
import Testing

@Suite("MovePart")
struct MovePartTests {
    /// Flute (one staff) and piano (grand staff, so it carries a brace), plus the score-start tempo `Score.blank`
    /// anchors on the very first staff — enough to watch a part, a bracket and a system-element address all move.
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
            measureCount: 2,
        ))
    }

    private func bracketedTrio() -> Score {
        Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [
                .init(instrumentID: "a", staves: [.init(clefType: "G")]),
                .init(instrumentID: "b", staves: [.init(clefType: "G")]),
                .init(instrumentID: "c", staves: [.init(clefType: "F")]),
            ],
            bracketGroups: [0 ..< 3],
            measureCount: 2,
        ))
    }

    @Test("a move is a removal followed by an insertion at the destination index")
    func moveReordersTheParts() throws {
        var score = duet()
        let original = score
        let inverse = try MovePart(from: 0, to: 1).apply(to: &score)
        #expect(score.parts.map(\.instrument.id) == ["piano", "flute"])
        // The part travels whole — its id, staves and bars are the same values, not rebuilt ones.
        #expect(score.parts[1] == original.parts[0])
        #expect(score.parts[0] == original.parts[1])
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("moving backwards shifts the parts between the two indices the other way")
    func moveBackwardsReordersTheParts() throws {
        var score = bracketedTrio()
        let original = score
        let inverse = try MovePart(from: 2, to: 0).apply(to: &score)
        #expect(score.parts.map(\.instrument.id) == ["c", "a", "b"])
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("undo restores the exact score, from every index to every other", arguments: [0, 1, 2], [0, 1, 2])
    func moveUndoesExactly(from: Int, to: Int) throws {
        var score = bracketedTrio()
        let original = score
        let inverse = try MovePart(from: from, to: to).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// The one field in the model that embeds a part index. A tempo written on the flute has to still name the
    /// flute after the flute has moved — the whole point of `originalStaff` is that it survives re-layout.
    @Test("a system element's anchor follows its part through the permutation")
    func moveRestampsSystemElementAddresses() throws {
        var score = duet()
        score.systemMeasures[1].elements.append(PositionedSystemElement(
            position: .start,
            element: .tempo(Tempo(beatsPerSecond: 3)),
            originalStaff: StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ))
        let original = score
        let inverse = try MovePart(from: 0, to: 1).apply(to: &score)
        // The flute was part 0 and is now part 1; the piano was part 1 and is now part 0.
        #expect(score.systemMeasures[0].elements[0].originalStaff == StaffAddress(partIndex: 1, staffIndexInPart: 0))
        #expect(score.systemMeasures[1].elements[0].originalStaff == StaffAddress(partIndex: 0, staffIndexInPart: 1))
        #expect(score.staffDisplayName(at: StaffAddress(partIndex: 1, staffIndexInPart: 0)) == "Flute")
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A brace belongs to the part it braces, so it travels with it rather than staying behind on whatever staff
    /// inherits the old index.
    @Test("a brace travels with the part it braces")
    func moveCarriesABraceWithItsPart() throws {
        var score = duet()
        #expect(score.parts[1].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
        _ = try MovePart(from: 1, to: 0).apply(to: &score)
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
        #expect(score.parts[1].staves[0].brackets.isEmpty)
    }

    /// A group bracket follows its anchor staff carrying its DECLARED span, even to the bottom of the score where
    /// only one staff is left below it. Clamping belongs to the layout engine (`LayoutEngine.buildBrackets` caps
    /// the last spanned staff, mirroring MuseScore's `BracketItem::staffIdx2`), and MuseScore's own
    /// `Score::sortStaves` reorders parts without touching spans.
    ///
    /// Driven as two FORWARD moves with no undo between them, because that is the case a model-level clamp would
    /// break and undo could not repair: away and back has to leave the score exactly as it started, rather than
    /// leaving a group bracket permanently shrunk to a span-1 stub — which MuseScore would then draw, having
    /// hidden the collapsed one.
    @Test("a group bracket keeps its declared span through a move to the bottom and back")
    func movePreservesADeclaredBracketSpan() throws {
        var score = bracketedTrio()
        let original = score
        _ = try MovePart(from: 0, to: 2).apply(to: &score)
        #expect(score.parts.map(\.instrument.id) == ["b", "c", "a"])
        #expect(score.parts[2].staves[0].brackets == [BracketItem(type: .normal, span: 3)])
        #expect(score.parts[0].staves[0].brackets.isEmpty)
        _ = try MovePart(from: 2, to: 0).apply(to: &score)
        #expect(score == original)
    }

    @Test("an out-of-range source index is refused", arguments: [-1, 3])
    func moveOutOfRangeSourceIsRefused(from: Int) {
        var score = bracketedTrio()
        #expect(throws: SheetMusicError.self) {
            try MovePart(from: from, to: 0).apply(to: &score)
        }
    }

    @Test("an out-of-range destination index is refused", arguments: [-1, 3])
    func moveOutOfRangeDestinationIsRefused(to: Int) {
        var score = bracketedTrio()
        #expect(throws: SheetMusicError.self) {
            try MovePart(from: 0, to: to).apply(to: &score)
        }
    }

    @Test("both out-of-range refusals name a missing target, not some other reason")
    func moveOutOfRangeRefusalIsTargetNotFound() {
        var score = bracketedTrio()
        do {
            _ = try MovePart(from: 0, to: 9).apply(to: &score)
            Issue.record("expected a refusal")
        } catch let SheetMusicError.invalidEdit(refusal) {
            #expect(refusal.operation == "MovePart")
            guard case .targetNotFound = refusal.reason else {
                Issue.record("expected .targetNotFound, got \(refusal.reason)")
                return
            }
        } catch {
            Issue.record("expected an invalidEdit refusal, got \(error)")
        }
    }
}
