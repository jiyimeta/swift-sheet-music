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
