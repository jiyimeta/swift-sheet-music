@testable import SheetMusicCore
import Testing

@Suite("Part commands")
struct PartCommandTests {
    /// Two-part score — flute (one staff) and piano (grand staff) — 3 measures, a mid-score key change on
    /// measure 1 of every staff, and a whole-note chord on the flute's first bar so content survival is
    /// observable across an add / undo round trip.
    private func fixture() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "t",
            parts: [
                .init(instrumentID: "flute", longName: "Flute", staves: [.init(clefType: "G")], gmProgram: 73),
                .init(
                    instrumentID: "piano", longName: "Piano",
                    staves: [.init(clefType: "G"), .init(clefType: "F")],
                ),
            ],
            concertKey: 0, timeNumerator: 4, timeDenominator: 4,
            tempoBPM: 120, measureCount: 3,
        ))
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures[1].voices[0].elements
                    .insert(.keySignature(KeySignature(concertKey: 2)), at: 0)
            }
        }
        // A natural C, so `MeasureAccidentals` has no glyph repair to bundle onto the edit under test.
        score.parts[0].staves[0].measures[0].voices[0].elements[2] =
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))
        return score
    }

    private static let clarinet = BlankScoreTemplate.PartPlan(
        instrumentID: "clarinet-bb", longName: "Clarinet in B♭",
        staves: [.init(clefType: "G")],
        transposeDiatonic: -1, transposeChromatic: -2, gmProgram: 71,
    )

    private func signatures(of measure: Measure) -> [VoiceElement] {
        measure.voices[0].elements.filter {
            switch $0 {
            case .keySignature, .timeSignature: true
            default: false
            }
        }
    }

    // MARK: - AddPart

    @Test("insert lands a rest column with the score's signature skeleton, and shifts the parts after it")
    func addPartInsertsRestColumnEverywhere() {
        let session = ScoreEditSession(score: fixture())
        let original = session.score
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 1)))
        let score = session.score

        #expect(score.parts.count == 3)
        #expect(score.parts[1].instrument.id == "clarinet-bb")
        #expect(score.parts[1].instrument.transposeChromatic == -2)
        #expect(score.parts[1].instrument.channel.program == 71)
        #expect(score.parts[1].staves.count == 1)
        #expect(score.parts[1].staves[0].measures.count == 3)
        #expect(score.parts[1].staves[0].defaultClefType == "G")

        // The signature skeleton is copied: bar 0 carries key + time, bar 1 the mid-score key change, bar 2
        // nothing. Every bar is otherwise a single measure rest.
        let new = score.parts[1].staves[0].measures
        #expect(signatures(of: new[0]) == [
            .keySignature(KeySignature(concertKey: 0)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ])
        #expect(signatures(of: new[1]) == [.keySignature(KeySignature(concertKey: 2))])
        #expect(signatures(of: new[2]).isEmpty)
        #expect(new[2].voices[0].elements == [.rest(duration: .measure)])
        // No clef is copied — the new part declares its own via `defaultClefType`.
        #expect(!new[0].voices[0].elements.contains { if case .clef = $0 { true } else { false } })

        // The parts either side are untouched, only re-indexed: the piano was part 1 and is now part 2.
        #expect(score.parts[0] == original.parts[0])
        #expect(score.parts[2] == original.parts[1])
        #expect(score.parts[2].staves.count == 2)
        #expect(score.systemMeasures.count == 3)
    }

    @Test("the flute's chord survives the insert and the undo")
    func addPartLeavesExistingContentAlone() {
        let session = ScoreEditSession(score: fixture())
        let original = session.score
        let chord = original.parts[0].staves[0].measures[0].voices[0].elements[2]
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 0)))
        // The flute is now part 1.
        #expect(session.score.parts[1].staves[0].measures[0].voices[0].elements[2] == chord)
        #expect(session.undo())
        #expect(session.score.parts[0].staves[0].measures[0].voices[0].elements[2] == chord)
    }

    @Test("undo restores the exact score, at every insertion index", arguments: [0, 1, 2])
    func addPartUndoRestoresExactScore(index: Int) {
        let original = fixture()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.addPart(plan: Self.clarinet, at: index)))
        #expect(session.score != original)
        #expect(session.undo())
        #expect(session.score == original)
    }

    @Test("the new part's id is unique against every id already in the score")
    func addPartGeneratesUniquePartID() {
        let session = ScoreEditSession(score: fixture())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 2)))
        #expect(Set(session.score.parts.map(\.id)).count == session.score.parts.count)
        #expect(session.score.parts[2].id == "3")
    }

    /// Ids in a loaded file need not be dense, or even numeric — the next id has to clear the maximum, not
    /// the count.
    @Test("the new id clears the highest existing numeric id, not the part count")
    func addPartIDClearsTheHighestExistingID() {
        var score = fixture()
        score.parts[0].id = "9"
        score.parts[1].id = "notANumber"
        let session = ScoreEditSession(score: score)
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 2)))
        #expect(session.score.parts[2].id == "10")
    }

    @Test("a system element anchored at or after the insertion point is re-stamped one part down")
    func addPartRestampsSystemElementAddresses() throws {
        let session = ScoreEditSession(score: fixture())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 0)))
        let tempo = try #require(session.score.systemMeasures[0].elements.first)
        let anchor = try #require(tempo.originalStaff)
        #expect(anchor == StaffAddress(partIndex: 1, staffIndexInPart: 0))
        // The address still resolves, and still names the flute it was anchored to.
        #expect(session.score.staffDisplayName(at: anchor) == "Flute")
    }

    @Test("a percussion plan's bars carry the time signature but never a key")
    func addPartBuildsPercussionBarsWithoutKeySignatures() {
        let session = ScoreEditSession(score: fixture())
        let drums = BlankScoreTemplate.PartPlan(
            instrumentID: "drumset", longName: "Drum Kit",
            staves: [.init(clefType: "PERC", isPercussion: true)], isDrums: true,
        )
        #expect(session.apply(.addPart(plan: drums, at: 2)))
        let measures = session.score.parts[2].staves[0].measures
        #expect(signatures(of: measures[0]) == [.timeSignature(TimeSignature(numerator: 4, denominator: 4))])
        #expect(signatures(of: measures[1]).isEmpty)
        #expect(session.score.parts[2].staves[0].group == "percussion")
        #expect(session.score.parts[2].instrument.useDrumset)
    }

    @Test("an out-of-range index is refused as a missing target", arguments: [-1, 4])
    func addPartOutOfRangeIsRefused(index: Int) {
        let session = ScoreEditSession(score: fixture())
        #expect(!session.apply(.addPart(plan: Self.clarinet, at: index)))
        guard case .targetNotFound? = session.lastRefusal?.reason else {
            Issue.record("expected .targetNotFound, got \(String(describing: session.lastRefusal?.reason))")
            return
        }
    }

    @Test("appending at parts.count is in range")
    func addPartAppends() {
        let session = ScoreEditSession(score: fixture())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 2)))
        #expect(session.score.parts.count == 3)
        #expect(session.score.parts[2].instrument.id == "clarinet-bb")
    }

    // MARK: - Brackets

    /// Three single-staff parts under one group bracket, so the bracket's span is exactly the flattened staff
    /// count and every insertion index exercises a different branch of the growth rule.
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

    @Test("a bracket whose span crosses the insertion point grows by the inserted staff count")
    func addPartGrowsACrossedBracket() {
        let session = ScoreEditSession(score: bracketedTrio())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: 1)))
        #expect(session.score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 4)])
    }

    @Test("a two-staff part inserted inside a bracket grows it by two")
    func addPartGrowsACrossedBracketByEveryInsertedStaff() {
        let session = ScoreEditSession(score: bracketedTrio())
        let piano = BlankScoreTemplate.PartPlan(
            instrumentID: "piano", staves: [.init(clefType: "G"), .init(clefType: "F")],
        )
        #expect(session.apply(.addPart(plan: piano, at: 2)))
        #expect(session.score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 5)])
        // The new part keeps its own brace, anchored on its top staff.
        #expect(session.score.parts[2].staves[0].brackets == [BracketItem(type: .brace, span: 2)])
    }

    @Test("a bracket the insertion falls outside of keeps its span", arguments: [0, 3])
    func addPartLeavesUncrossedBracketsAlone(index: Int) {
        let session = ScoreEditSession(score: bracketedTrio())
        #expect(session.apply(.addPart(plan: Self.clarinet, at: index)))
        let anchor = index == 0 ? 1 : 0
        #expect(session.score.parts[anchor].staves[0].brackets == [BracketItem(type: .normal, span: 3)])
    }

    @Test("undo restores a grown bracket byte-for-byte", arguments: [0, 1, 2, 3])
    func addPartBracketGrowthUndoesExactly(index: Int) {
        let original = bracketedTrio()
        let session = ScoreEditSession(score: original)
        #expect(session.apply(.addPart(plan: Self.clarinet, at: index)))
        #expect(session.undo())
        #expect(session.score == original)
    }

    // MARK: - RemovePart (the inverse; its intent ships with the move / remove work)

    @Test("removing a part drops its column and re-indexes the ones after it")
    func removePartDropsTheColumn() throws {
        var score = fixture()
        let original = score
        let inverse = try RemovePart(partIndex: 0).apply(to: &score)
        #expect(score.parts.count == 1)
        #expect(score.parts[0].instrument.id == "piano")
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A tempo anchored into the part being removed has to land somewhere valid — dropping the element would
    /// silently take the score's tempo with the instrument.
    @Test("a system element anchored into the removed part re-anchors on the first staff")
    func removePartReanchorsSystemElementsPointingIntoIt() throws {
        var score = fixture()
        score.systemMeasures[1].elements.append(PositionedSystemElement(
            position: .start,
            element: .tempo(Tempo(beatsPerSecond: 3)),
            originalStaff: StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ))
        let original = score
        let inverse = try RemovePart(partIndex: 1).apply(to: &score)
        #expect(score.systemMeasures[1].elements.count == 1)
        #expect(
            score.systemMeasures[1].elements[0].originalStaff
                == StaffAddress(partIndex: 0, staffIndexInPart: 0),
        )
        // Still the tempo, not a placeholder.
        guard case .tempo = score.systemMeasures[1].elements[0].element else {
            Issue.record("the tempo did not survive its anchor part's removal"); return
        }
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("a cross-part bracket shrinks over the removed staves and comes back on undo")
    func removePartShrinksACrossPartBracket() throws {
        var score = bracketedTrio()
        let original = score
        let inverse = try RemovePart(partIndex: 1).apply(to: &score)
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 2)])
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// The bracket's anchor staff itself goes away, so the bracket has to re-anchor on the first survivor in
    /// its window rather than vanish — the same rule `Score.filtered(hidingStaves:)` applies.
    @Test("removing a bracket's anchor part re-anchors the bracket on the next staff it covered")
    func removePartReanchorsABracketWhoseAnchorItRemoves() throws {
        var score = bracketedTrio()
        let original = score
        let inverse = try RemovePart(partIndex: 0).apply(to: &score)
        #expect(score.parts[0].staves[0].brackets == [BracketItem(type: .normal, span: 2)])
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("an out-of-range part index is refused")
    func removePartOutOfRangeIsRefused() {
        var score = fixture()
        #expect(throws: SheetMusicError.self) {
            try RemovePart(partIndex: 7).apply(to: &score)
        }
    }
}
