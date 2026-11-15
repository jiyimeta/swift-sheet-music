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

    private func appending(_ element: PositionedSystemElement, toMeasure measureIndex: Int, in score: inout Score) {
        score.systemMeasures.updateValue(at: measureIndex) { column in
            let pairs = column.elements.indices.map { (column.elements.eid(at: $0), column.elements[$0]) }
            column.elements = IdentifiedArray(pairs + [(.invalid, element)])
        }
    }

    private func systemSpanners(on staff: StaffAddress, measure measureIndex: Int, in score: Score) -> [Spanner] {
        let measure = score[measure: MeasureRef(measureIndex: measureIndex), staff: staff]
        return (measure?.voices ?? []).flatMap(\.elements.values).compactMap {
            guard case let .spanner(spanner) = $0, SystemSpannerHoist.isSystemSpanner($0) else { return nil }
            return spanner
        }
    }

    /// Puts `elements` at the head of bar `measureIndex`'s first voice on `staff`, ahead of what is there.
    private func prepending(
        _ elements: [VoiceElement], toMeasure measureIndex: Int, on staff: StaffAddress, in score: inout Score,
    ) throws {
        let ref = MeasureRef(measureIndex: measureIndex)
        var measure = try #require(score[measure: ref, staff: staff])
        let existing = measure.voices[0].elements
        measure.voices[0].elements = IdentifiedArray(
            elements.map { (EID.invalid, $0) } + existing.indices.map { (existing.eid(at: $0), existing[$0]) },
        )
        score[measure: ref, staff: staff] = measure
    }

    private static let volta = VoiceElement.spanner(
        Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1, voltaEndings: [1]),
    )
    private static let rit = VoiceElement.spanner(
        Spanner(kind: .gradualTempoChange, rawType: "GradualTempoChange", nextMeasuresOffset: 1),
    )

    /// MuseScore leaves a system object written on the top staff on track 0 when `Score::sortStaves` renumbers the
    /// rest (`EngravingItem::isTopSystemObject`), so the score's tempo and rehearsal marks print over whichever part
    /// is first. They used to ride the permutation with the part that had been first — the reported bug: drag the
    /// second part to the top, and the tempo and the rehearsal mark stayed on the part now second.
    @Test("a score-wide mark on the top staff stays on top, whichever part moves", arguments: [(0, 1), (1, 0)])
    func moveKeepsTopSystemObjectsOnTop(from: Int, to: Int) throws {
        var score = duet()
        // `Score.blank` writes its opening tempo on (0, 0) by name, as an imported file does.
        #expect(score.systemMeasures[0].elements[0].originalStaff == Score.canonicalStaff)
        appending(PositionedSystemElement(
            position: .start, element: .rehearsalMark(RehearsalMark(text: "A")),
            originalStaff: Score.canonicalStaff,
        ), toMeasure: 1, in: &score)
        appending(PositionedSystemElement(
            position: .start, element: .staffText(StaffText(text: "Swing", isSystemText: true)),
        ), toMeasure: 1, in: &score)
        let original = score
        let inverse = try MovePart(from: from, to: to).apply(to: &score)
        #expect(score.parts.map(\.instrument.id) == ["piano", "flute"])
        #expect(score.systemMeasures[0].elements[0].originalStaff == Score.canonicalStaff)
        #expect(score.systemMeasures[1].elements.map(\.originalStaff) == [Score.canonicalStaff, nil])
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A staff-bound mark still names the staff it was written on — the part it belongs to, wherever that goes —
    /// and so does a score-wide one written on a lower staff. A staff-bound mark with no staff is on the top staff,
    /// so it belongs to the part that was first.
    @Test("a staff-bound mark and a lower staff's mark follow their part through the permutation")
    func moveRestampsPartBoundSystemElements() throws {
        var score = duet()
        appending(PositionedSystemElement(
            position: .start, element: .staffText(StaffText(text: "pizz.")), originalStaff: Score.canonicalStaff,
        ), toMeasure: 1, in: &score)
        appending(PositionedSystemElement(
            position: .start, element: .tempo(Tempo(beatsPerSecond: 3)),
            originalStaff: StaffAddress(partIndex: 1, staffIndexInPart: 1),
        ), toMeasure: 1, in: &score)
        appending(PositionedSystemElement(
            position: .start, element: .staffText(StaffText(text: "con sord.")),
        ), toMeasure: 1, in: &score)
        let original = score
        let inverse = try MovePart(from: 0, to: 1).apply(to: &score)
        // The flute was part 0 and is now part 1; the piano was part 1 and is now part 0.
        #expect(score.systemMeasures[1].elements.map(\.originalStaff) == [
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
        ])
        #expect(score.staffDisplayName(at: StaffAddress(partIndex: 1, staffIndexInPart: 0)) == "Flute")
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A volta and a gradual tempo change live in the top staff's voices, not in the lane, and MuseScore keeps them
    /// on track 0 as it keeps a tempo. Left in the part, they printed over the part that was now second.
    @Test("the top staff's voltas and gradual tempo changes move to the new top staff, and back on undo")
    func moveHoistsSystemSpanners() throws {
        var score = duet()
        try prepending([Self.volta, Self.rit], toMeasure: 1, on: Score.canonicalStaff, in: &score)
        let original = score
        let piano = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let flute = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let inverse = try MovePart(from: 1, to: 0).apply(to: &score)
        #expect(score.parts.map(\.instrument.id) == ["piano", "flute"])
        #expect(systemSpanners(on: piano, measure: 1, in: score).map(\.kind) == [.volta, .gradualTempoChange])
        #expect(systemSpanners(on: flute, measure: 1, in: score).isEmpty)
        // Still the first two elements of the bar, in the order they were written, so playback and layout read them
        // where a volta and a line starting on the bar's first rest are written.
        let head = try #require(score[measure: MeasureRef(measureIndex: 1), staff: piano]).voices[0].elements
        #expect(head[0] == Self.volta)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A gradual tempo change hangs on the chord it starts at. Where the new top staff starts nothing at that beat
    /// there is nothing to hang it on, so it stays where it was rather than moving to a different beat.
    @Test("a gradual tempo change with no chord to hang on in the new top staff stays where it is")
    func moveLeavesAnUnplaceableGradualTempoChange() throws {
        var score = duet()
        let ref = MeasureRef(measureIndex: 1)
        var bar = try #require(score[measure: ref, staff: Score.canonicalStaff])
        bar.voices[0].elements = IdentifiedArray([
            .chord(Chord(duration: .half, notes: [Note(pitch: 72, tpc: 14)])),
            Self.rit,
            .chord(Chord(duration: .half, notes: [Note(pitch: 74, tpc: 16)])),
        ])
        score[measure: ref, staff: Score.canonicalStaff] = bar
        let original = score
        let inverse = try MovePart(from: 1, to: 0).apply(to: &score)
        // The piano's bar is one measure rest: nothing starts at beat 3.
        #expect(systemSpanners(on: StaffAddress(partIndex: 0, staffIndexInPart: 0), measure: 1, in: score).isEmpty)
        #expect(systemSpanners(on: StaffAddress(partIndex: 1, staffIndexInPart: 0), measure: 1, in: score).map(\.kind)
            == [.gradualTempoChange])
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
