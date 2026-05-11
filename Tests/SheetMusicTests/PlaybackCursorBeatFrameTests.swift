import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

/// Regression coverage for `LayoutDocument.cursorFrame` on `.beat`
/// cursors landing in measures whose visible voices carry no anchor-
/// able content (e.g. only a whole-measure rest). The fallback used
/// to spread beats linearly from the measure's left edge — which
/// placed the cursor at x=0 of the measure, visually sitting on top
/// of any leading clef / key signature / time signature.
@Suite("PlaybackCursorView beat fallback respects leading header")
struct PlaybackCursorBeatFrameTests {
    /// Single-measure score whose only voice element is a whole rest.
    /// The first system auto-synthesizes a leading clef, so the
    /// resulting layout measure has a header glyph at its left edge
    /// even though the score declares none.
    private static func wholeRestScore(division: Int = 480) -> Score {
        let voice = Voice(elements: [
            .chord(Chord(duration: .whole, notes: [])),
        ])
        let staff = Staff(measures: [Measure(voices: [voice])])
        return Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff],
            )],
        )
    }

    /// Same shape as `wholeRestScore` but the voice also carries an
    /// explicit time signature in front of the whole rest. Forces the
    /// header schedule to reserve a time-sig column the fix must
    /// account for in addition to the clef.
    private static func wholeRestScoreWithTimeSig(division: Int = 480) -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .whole, notes: [])),
        ])
        let staff = Staff(measures: [Measure(voices: [voice])])
        return Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff],
            )],
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func laidOut(_ s: Score) -> LayoutDocument {
        let opts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        )
        let natW = LayoutEngine.naturalContentWidth(
            score: s, options: opts,
        )
        return LayoutEngine.layout(
            score: s, options: opts, availableWidth: natW,
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func cursorXInMeasure(
        _ doc: LayoutDocument,
        score: Score,
        cursor: ScoreCursor,
    ) throws -> CGFloat {
        let system = try #require(doc.systems.first)
        let measure = try #require(system.measures.first)
        let frame = try #require(doc.cursorFrame(for: cursor, in: score))
        let halfW = doc.metrics.sp * 0.4
        let cursorCenterX = frame.minX + halfW
        let measureLeftX = system.origin.x + measure.origin.x
        return cursorCenterX - measureLeftX
    }

    @Test("beat tick 0 in a whole-rest measure sits past the leading clef")
    func cursorPastLeadingClef() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.wholeRestScore()
        let doc = Self.laidOut(score)
        let x = try Self.cursorXInMeasure(
            doc, score: score,
            cursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        // Synthesized clef glyph spans roughly [sp*2, sp*4]. The
        // cursor must sit at or past the clef's right edge — not on
        // top of the glyph and not at the measure's left edge.
        #expect(x >= doc.metrics.sp * 4)
    }

    @Test("beat tick 0 in a whole-rest measure sits past leading clef + time sig")
    func cursorPastLeadingClefAndTimeSig() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.wholeRestScoreWithTimeSig()
        let doc = Self.laidOut(score)
        let xWithTimeSig = try Self.cursorXInMeasure(
            doc, score: score,
            cursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        let bare = try Self.cursorXInMeasure(
            Self.laidOut(Self.wholeRestScore()),
            score: Self.wholeRestScore(),
            cursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        // Adding a leading time signature reserves an additional
        // column — the cursor's measure-local X must shift further
        // to the right to clear it.
        #expect(xWithTimeSig > bare)
    }
}
