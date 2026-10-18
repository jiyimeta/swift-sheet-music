#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Where a measure's columns stand against its right edge.
///
/// `TickAggregate.trailingGap` is counted into a measure's width after its content, but `tickColumns` hands its sp
/// back to the content, so nothing of it is left empty before the barline: the last gap runs to the measure's right
/// edge. A floor that took the sp as empty room came out a whole sp short — the bar-end grace notes ran into their own
/// chord once lines were laid out at their natural width (2026-10-18). This pins the geometry those floors measure
/// from.
@Suite("Tick columns against the measure's right edge")
struct TickColumnTrailingEdgeTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("at its minimum width a bar of equal notes stands its last one gap from the edge, as each from the next")
    func lastColumnStandsOneGapFromTheEdge() throws {
        let note = Note(pitch: 71, tpc: 19)
        let chords = (0 ..< 4).map { _ in VoiceElement.chord(Chord(duration: .quarter, notes: [note])) }
        let staves = [Staff(measures: [Measure(voices: [Voice(elements: chords)])])]
        let metrics = StaffMetrics(staffSize: 28)
        let header = LayoutEngine.computeHeaderSchedule(
            measureIdx: 0, staves: staves, metrics: metrics, synthesizeClefForAllStaves: false,
        )
        let measured = LayoutEngine.crossStaffMinimumMeasureWidthWithAggregate(
            staves: staves, measureIdx: 0, metrics: metrics, headerSchedule: header, division: 480,
            measureDuration: Fraction(numerator: 4, denominator: 4), graceNoteMag: ScoreViewOptions().graceNoteMag,
            chordSymbolCase: .museScoreDefaults,
        )
        let columns = LayoutEngine.tickColumns(
            aggregate: measured.aggregate, metrics: metrics, headerSchedule: header, width: measured.width,
        )
        let xs = columns.sorted { $0.key < $1.key }.map(\.value)
        try #require(xs.count == 4)
        let gaps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 0.001 }, "\(gaps)")
        #expect(abs(measured.width - xs[3] - gaps[0]) < 0.001, "edge \(measured.width - xs[3]) vs gap \(gaps[0])")
    }
}
