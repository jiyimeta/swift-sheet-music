@testable import SheetMusicCore
import Testing

/// The two rehearsal-mark commands: what they write into `Score.systemMeasures`, what they preserve on a rename,
/// and that each one's returned inverse restores the lane byte-for-byte — padding included.
@Suite("Rehearsal mark commands")
struct RehearsalMarkCommandTests {
    /// Four bars of quarter rests on one staff, with an EMPTY system lane — the shape `Score.blank` produces and
    /// the one the padding rule exists for.
    private static func blankScore() -> Score {
        let staff = Staff(measures: (0 ..< 4).map { _ in
            Measure(voices: [Voice(elements: Array(repeating: .rest(duration: .quarter), count: 4))])
        })
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    private static func markText(in score: Score, measureIndex: Int) -> String? {
        RehearsalMarkLane.mark(in: score, measureIndex: measureIndex)?.text
    }

    @Test("writing a mark into an empty lane pads it to one entry per measure")
    func writePadsLane() throws {
        var score = Self.blankScore()
        #expect(score.systemMeasures.isEmpty)
        try SetRehearsalMark(measureIndex: 2, text: "A").apply(to: &score)
        #expect(score.systemMeasures.count == 4)
        #expect(Self.markText(in: score, measureIndex: 2) == "A")
        #expect(Self.markText(in: score, measureIndex: 0) == nil)
    }

    @Test("the mark sits at the head of the bar")
    func writtenAtStart() throws {
        var score = Self.blankScore()
        try SetRehearsalMark(measureIndex: 1, text: "B").apply(to: &score)
        let positioned = try #require(score.systemMeasures[1].elements.first)
        #expect(positioned.position == .start)
        #expect(positioned.originalStaff == nil)
    }

    @Test("renaming preserves the mark's frame, color and offsets")
    func renamePreservesStyling() throws {
        var score = Self.blankScore()
        score.systemMeasures = Array(repeating: SystemMeasure(), count: 4)
        var styled = RehearsalMark(text: "A", offsetX: 1.5, offsetY: -2, frame: .circle)
        styled.visible = false
        score.systemMeasures[1].elements = [
            PositionedSystemElement(position: .start, element: .rehearsalMark(styled)),
        ]
        try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        let mark = try #require(RehearsalMarkLane.mark(in: score, measureIndex: 1))
        #expect(mark.text == "Coda")
        #expect(mark.frame == .circle)
        #expect(mark.offsetX == 1.5)
        #expect(mark.offsetY == -2)
        #expect(mark.visible == false)
    }

    @Test("the inverse restores the lane exactly, padding included")
    func inverseRestoresLane() throws {
        var score = Self.blankScore()
        let before = score.systemMeasures
        let inverse = try SetRehearsalMark(measureIndex: 2, text: "A").apply(to: &score)
        try inverse.apply(to: &score)
        #expect(score.systemMeasures == before)
    }

    @Test("removing drops the mark, and its inverse puts it back")
    func removeAndUndo() throws {
        var score = Self.blankScore()
        try SetRehearsalMark(measureIndex: 2, text: "A").apply(to: &score)
        let seeded = score.systemMeasures
        let inverse = try RemoveRehearsalMark(measureIndex: 2).apply(to: &score)
        #expect(Self.markText(in: score, measureIndex: 2) == nil)
        // The removal drops the mark, not the padding the write put there: the lane stays one entry per measure,
        // which is what `InsertMeasure` / `DeleteMeasure` test for before they will keep maintaining it.
        #expect(score.systemMeasures.count == 4)
        try inverse.apply(to: &score)
        #expect(score.systemMeasures == seeded)
    }

    /// A bar carrying two marks is not something this pair's own writes can produce — one bar holds one mark — but
    /// an import can, and a removal that took only the first would leave the bar still marked.
    @Test("a removal drops every mark the bar carries")
    func removeDropsEveryMark() throws {
        var score = Self.blankScore()
        score.systemMeasures = Array(repeating: SystemMeasure(), count: 4)
        score.systemMeasures[1].elements = [
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: "A"))),
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: "B"))),
        ]
        try RemoveRehearsalMark(measureIndex: 1).apply(to: &score)
        let remaining = score.systemMeasures[1].elements.filter {
            if case .rehearsalMark = $0.element { true } else { false }
        }
        #expect(remaining.isEmpty)
    }

    /// A bar carrying two marks, the first distinguishable from the second by its styling, so the assertions below
    /// can tell which one survived the collapse. A tempo rides along to pin that the collapse takes rehearsal marks
    /// and nothing else.
    private static func twoMarkScore() -> Score {
        var score = blankScore()
        score.systemMeasures = Array(repeating: SystemMeasure(), count: 4)
        score.systemMeasures[1].elements = [
            PositionedSystemElement(
                position: .start, element: .rehearsalMark(RehearsalMark(text: "A", offsetX: 3, frame: .circle)),
            ),
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2))),
            PositionedSystemElement(
                position: .start, element: .rehearsalMark(RehearsalMark(text: "B", offsetX: -7, frame: .none)),
            ),
        ]
        return score
    }

    private static func marks(in score: Score, measureIndex: Int) -> [RehearsalMark] {
        score.systemMeasures[measureIndex].elements.compactMap { RehearsalMarkLane.mark(of: $0.element) }
    }

    /// The write is the one operation that can leave a bar agreeing with itself: the read returns the FIRST mark and
    /// the removal drops every one, so a rename that touched only the first would leave the reading surface still
    /// listing a mark the sheet never showed.
    @Test("writing a mark collapses a bar that carried several to one")
    func writeCollapsesMultipleMarks() throws {
        var score = Self.twoMarkScore()
        try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        let remaining = Self.marks(in: score, measureIndex: 1)
        #expect(remaining.count == 1)
        #expect(remaining.first?.text == "Coda")
    }

    /// The collapse keeps the FIRST mark and drops the rest, rather than the other way round — the first is the one
    /// the read returns, so it is the one whose frame, offsets and font overrides a rename has to carry through.
    @Test("the mark that survives the collapse is the first one, styling and all")
    func collapseKeepsTheFirstMarksStyling() throws {
        var score = Self.twoMarkScore()
        try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        let remaining = Self.marks(in: score, measureIndex: 1)
        #expect(remaining.count == 1)
        let survivor = try #require(remaining.first)
        #expect(survivor.text == "Coda")
        #expect(survivor.offsetX == 3)
        #expect(survivor.frame == .circle)
    }

    @Test("the collapse leaves the bar's other system elements alone")
    func collapseSparesOtherSystemElements() throws {
        var score = Self.twoMarkScore()
        try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        // The mark and the tempo, in that order, and nothing else: the second mark went and the tempo between the
        // two did not.
        #expect(score.systemMeasures[1].elements.count == 2)
        let tempos = score.systemMeasures[1].elements.compactMap { positioned -> Tempo? in
            if case let .tempo(tempo) = positioned.element { tempo } else { nil }
        }
        #expect(tempos.count == 1)
        #expect(tempos.first?.beatsPerSecond == 2)
    }

    /// The inverse captures the whole `systemMeasures` lane by value, so undoing a collapse is the same restore as
    /// undoing any other mark write — the dropped mark comes back with it.
    @Test("undoing a collapse puts both marks back")
    func undoRestoresCollapsedMarks() throws {
        var score = Self.twoMarkScore()
        let before = score.systemMeasures
        let inverse = try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        #expect(Self.marks(in: score, measureIndex: 1).count == 1)
        try inverse.apply(to: &score)
        #expect(score.systemMeasures == before)
        #expect(Self.marks(in: score, measureIndex: 1).map(\.text) == ["A", "B"])
    }

    /// The same collapse with the surviving mark at index 1 rather than 0, because `twoMarkScore` alone cannot tell
    /// the correct `(index + 1)...` from a hardcoded `1...`: its survivor is always the bar's first element. The
    /// likelier slips are already fenced there — splicing from `index...` or filtering the whole array would take
    /// the survivor with them and leave no mark at all — but a hardcoded bound would pass every one of those and
    /// eat mark "A" here. New code that deletes elements gets the arithmetic pinned.
    @Test("the collapse is keyed to the surviving mark's own index, not to the bar's start")
    func collapseWhenTheMarkIsNotTheFirstElement() throws {
        var score = Self.blankScore()
        score.systemMeasures = Array(repeating: SystemMeasure(), count: 4)
        score.systemMeasures[1].elements = [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2))),
            PositionedSystemElement(
                position: .start, element: .rehearsalMark(RehearsalMark(text: "A", offsetX: 3, frame: .circle)),
            ),
            PositionedSystemElement(
                position: .start, element: .rehearsalMark(RehearsalMark(text: "B", offsetX: -7, frame: .none)),
            ),
        ]
        try SetRehearsalMark(measureIndex: 1, text: "Coda").apply(to: &score)
        #expect(score.systemMeasures[1].elements.count == 2)
        let remaining = Self.marks(in: score, measureIndex: 1)
        #expect(remaining.count == 1)
        let survivor = try #require(remaining.first)
        #expect(survivor.text == "Coda")
        #expect(survivor.offsetX == 3)
        #expect(survivor.frame == .circle)
    }

    @Test("empty and whitespace-only text is refused")
    func emptyTextRefused() {
        var score = Self.blankScore()
        #expect(throws: SheetMusicError.self) {
            try SetRehearsalMark(measureIndex: 0, text: "   ").apply(to: &score)
        }
        #expect(score.systemMeasures.isEmpty)
    }

    @Test("text is trimmed before it is written")
    func textIsTrimmed() throws {
        var score = Self.blankScore()
        try SetRehearsalMark(measureIndex: 0, text: "  A  ").apply(to: &score)
        #expect(Self.markText(in: score, measureIndex: 0) == "A")
    }

    @Test("an out-of-range bar is refused by both commands")
    func outOfRangeRefused() {
        var score = Self.blankScore()
        #expect(throws: SheetMusicError.self) {
            try SetRehearsalMark(measureIndex: 4, text: "A").apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            try RemoveRehearsalMark(measureIndex: -1).apply(to: &score)
        }
    }

    @Test("removing where there is no mark is refused")
    func removeWithoutMarkRefused() {
        var score = Self.blankScore()
        #expect(throws: SheetMusicError.self) {
            try RemoveRehearsalMark(measureIndex: 1).apply(to: &score)
        }
    }
}
