#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// The bar a point falls in, against a laid-out document, because "which bar is this point in" only means something
/// in coordinates the engraver produced. Moved from folino's `MeasureHitTestTests` with the rule it pins.
@Suite("LayoutDocument editingMeasureHit")
struct LayoutDocumentEditingMeasureHitTests {
    private let _install = TestSupport.installFontMetrics
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func quarterRests() -> [VoiceElement] {
        Array(repeating: .rest(duration: .quarter), count: 4)
    }

    /// One staff, three 4/4 bars of quarter rests.
    private static func threeBars() -> Score {
        let meter = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let bars = [Measure(voices: [Voice(elements: [meter] + quarterRests())])]
            + Array(repeating: Measure(voices: [Voice(elements: quarterRests())]), count: 2)
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])],
        )
    }

    /// Two one-staff parts of five bars: bar 0 opens with the meter and four quarter rests, bars 1–3 hold only a
    /// measure rest (the run that collapses), bar 4 holds four quarter rests. folino's
    /// `MultiMeasureRestSelectionTests.score()`.
    private static func runScore() -> Score {
        let meter = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let opening = Measure(voices: [Voice(elements: [meter] + quarterRests())])
        let empty = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let closing = Measure(voices: [Voice(elements: quarterRests())])
        let staff = Staff(measures: [opening, empty, empty, empty, closing])
        let parts = (0 ..< 2).map { index in
            Part(id: String(index + 1), instrument: Instrument(id: "x\(index)"), staves: [staff])
        }
        return Score(division: 480, parts: IdentifiedArray(parts))
    }

    private static func layout(_ score: Score, collapsing: Bool = false) -> LayoutDocument {
        LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 14, wrapToViewWidth: true,
                multiMeasureRest: collapsing ? .collapse(minimumMeasures: 2) : .disabled,
            ),
            availableWidth: 800,
        )
    }

    /// The bar's centre on its staff's top line, taken from the layout rather than guessed.
    private static func centre(ofMeasure index: Int, row: Int = 0, in document: LayoutDocument) -> CGPoint? {
        for system in document.systems {
            guard let measure = system.measures.first(where: { $0.measureIndex == index }),
                  system.staffOrigins.indices.contains(row)
            else { continue }
            return CGPoint(
                x: system.origin.x + measure.origin.x + measure.width / 2,
                y: system.origin.y + system.staffOrigins[row].y,
            )
        }
        return nil
    }

    @Test func `a point inside a bar names that bar`() throws {
        let document = Self.layout(Self.threeBars())
        for index in 0 ... 2 {
            let point = try #require(Self.centre(ofMeasure: index, in: document))
            let hit = document.editingMeasureHit(at: point)
            #expect(hit?.measureIndex == index)
            #expect(hit?.measures == index ... index)
            #expect(hit?.staff == Self.staff0)
        }
    }

    /// Half-open in x: the barline between two bars belongs to the bar that starts there, so a point on it is never
    /// claimed by both.
    @Test func `a bar's own left edge belongs to it and its right edge does not`() throws {
        let document = Self.layout(Self.threeBars())
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first { $0.measureIndex == 1 })
        let y = system.origin.y + (system.staffOrigins.first?.y ?? 0)
        let left = CGPoint(x: system.origin.x + measure.origin.x, y: y)
        let right = CGPoint(x: system.origin.x + measure.origin.x + measure.width, y: y)
        #expect(document.editingMeasureHit(at: left)?.measureIndex == 1)
        #expect(document.editingMeasureHit(at: right)?.measureIndex != 1)
    }

    @Test func `a point above every system names nothing`() {
        let document = Self.layout(Self.threeBars())
        #expect(document.editingMeasureHit(at: CGPoint(x: 100, y: -500)) == nil)
    }

    /// The paper above a staff is not the staff. The system box reaches several staff spaces past the top line, room
    /// for lyrics and chord symbols. A click a whole staff height above the music used to select the bar under it
    /// (folino user report, 2026-09-12).
    @Test func `a point clear above the staff names nothing`() throws {
        let document = Self.layout(Self.threeBars())
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first { $0.measureIndex == 1 })
        let x = system.origin.x + measure.origin.x + measure.width / 2
        let staffTop = system.origin.y + (system.staffOrigins.first?.y ?? 0)
        let sp = document.metrics.sp
        #expect(document.editingMeasureHit(at: CGPoint(x: x, y: staffTop - sp / 2))?.measureIndex == 1)
        #expect(document.editingMeasureHit(at: CGPoint(x: x, y: staffTop - sp * 2)) == nil)
    }

    /// The mirror image below the staff, where the system box overruns by less. That is why the band is measured from
    /// the staff and not from the box.
    @Test func `a point clear below the staff names nothing`() throws {
        let document = Self.layout(Self.threeBars())
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first { $0.measureIndex == 1 })
        let x = system.origin.x + measure.origin.x + measure.width / 2
        let staffTop = system.origin.y + (system.staffOrigins.first?.y ?? 0)
        let sp = document.metrics.sp
        let bottom = staffTop + system.geometry(atFlatIndex: 0).barLineSpanY(sp: sp).bottom
        #expect(document.editingMeasureHit(at: CGPoint(x: x, y: bottom + sp / 2))?.measureIndex == 1)
        #expect(document.editingMeasureHit(at: CGPoint(x: x, y: bottom + sp * 2)) == nil)
    }

    @Test func `a point past the last bar of a system names nothing`() throws {
        let document = Self.layout(Self.threeBars())
        let system = try #require(document.systems.first)
        let y = system.origin.y + (system.staffOrigins.first?.y ?? 0)
        let beyond = CGPoint(x: system.origin.x + system.size.width + 500, y: y)
        #expect(document.editingMeasureHit(at: beyond) == nil)
    }

    /// A collapsed run is ONE `LayoutMeasure` numbered after its first bar. The hit reports every bar it stands for,
    /// because nothing else can tell a click the interior bars are there.
    @Test func `a collapsed multi-measure rest reports its whole run`() throws {
        let document = Self.layout(Self.runScore(), collapsing: true)
        let system = try #require(document.systems.first { $0.measures.contains { $0.measureIndex == 1 } })
        let measure = try #require(system.measures.first { $0.measureIndex == 1 })
        #expect(measure.multiMeasureRest == 3, "bars 1-3 should lay out as one multi-measure rest")
        let point = try #require(Self.centre(ofMeasure: 1, row: 1, in: document))
        let hit = document.editingMeasureHit(at: CGPoint(x: point.x, y: point.y + 2 * document.metrics.sp))
        #expect(hit?.measureIndex == 1)
        #expect(hit?.measures == 1 ... 3)
        #expect(hit?.staff == StaffAddress(partIndex: 1, staffIndexInPart: 0))
    }

    /// Each staff owns its own band. The paper between two staves of a system belongs to neither.
    @Test func `the second staff owns its band and the gap between staves is paper`() throws {
        let document = Self.layout(Self.runScore())
        let lower = try #require(Self.centre(ofMeasure: 0, row: 1, in: document))
        #expect(document.editingMeasureHit(at: lower)?.staff == StaffAddress(partIndex: 1, staffIndexInPart: 0))

        let system = try #require(document.systems.first)
        let sp = document.metrics.sp
        let upperBottom = system.origin.y + system.staffOrigins[0].y
            + system.geometry(atFlatIndex: 0).barLineSpanY(sp: sp).bottom
        let lowerTop = system.origin.y + system.staffOrigins[1].y
            + system.geometry(atFlatIndex: 1).barLineSpanY(sp: sp).top
        try #require(lowerTop - upperBottom > 2 * sp, "the staves must be more than two margins apart")
        let gap = CGPoint(x: lower.x, y: (upperBottom + lowerTop) / 2)
        #expect(document.editingMeasureHit(at: gap) == nil)
    }
}
