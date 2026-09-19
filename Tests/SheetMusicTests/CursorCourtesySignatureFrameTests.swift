import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Regression coverage for the playback cursor in an EMPTY bar that ends a system where the next one changes key.
///
/// Such a bar has no column to anchor an interpolation on — its only content is a centered measure rest — so
/// `beatXInMeasure` spreads the beats across the bar's body, starting past the leading clef / key / time glyphs.
/// The courtesy key signature announcing the next system's key is drawn at the END of that bar, and taking the
/// maximum over every signature in the measure pushed that "leading header" out to the right margin: the body
/// collapsed and the cursor sat on the system's right edge for the whole bar (reported 2026-09-19).
@Suite("cursorFrame ignores a courtesy signature when it spreads an empty bar")
struct CursorCourtesySignatureTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Two bars on one staff: an empty one, then one that declares a new key. Laid out narrow enough that the
    /// second bar wraps onto its own system, which is what makes the first bar carry the courtesy signature.
    private static func keyChangeAfterEmptyBar(division: Int = 480) -> Score {
        let emptyBar = Measure(voices: [Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .measure),
        ])])
        let keyChangeBar = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: 4)),
            .chord(Chord(duration: .whole, notes: [Note(pitch: 64, tpc: 18)])),
        ])])
        return Score(
            division: division,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [emptyBar, keyChangeBar])],
            )],
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test("the cursor starts at the empty bar's left, not on its courtesy signature")
    func emptyBarBeforeKeyChangeSpreadsFromTheLeft() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.keyChangeAfterEmptyBar()
        let options = ScoreViewOptions(staffSize: 28, systemGap: 40, wrapToViewWidth: true)
        // Narrow enough that the two bars cannot share a system.
        let natural = LayoutEngine.naturalContentWidth(score: score, options: options)
        let doc = LayoutEngine.layout(score: score, options: options, availableWidth: natural * 0.6)

        // The empty bar must have ended up on a system of its own, with the key change on the next one — the
        // arrangement that engraves the courtesy signature. Without it this test would pass vacuously.
        try #require(doc.systems.count >= 2)
        let system = try #require(doc.systems.first)
        let measure = try #require(system.measures.first { $0.measureIndex == 0 })
        let carriesCourtesySignature = measure.elements.contains { element in
            if case let .keySignature(_, _, _, _, origin, _) = element {
                origin.x > measure.width / 2
            } else {
                false
            }
        }
        try #require(carriesCourtesySignature)

        let frame = try #require(
            doc.cursorFrame(for: .beat(measureIndex: 0, tickInMeasure: 0), in: score),
        )
        let base = system.origin.x + measure.origin.x
        // Beat one belongs in the bar's left half whatever is engraved at its right edge.
        #expect(frame.midX < base + measure.width / 2)
    }
}
