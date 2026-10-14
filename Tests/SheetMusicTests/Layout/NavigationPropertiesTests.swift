#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// `own/marker-properties.mscx` laid out: a segno at `<musicSymbolSize>24`, a hidden To Coda, a red D.S. al Coda offset
/// two spaces left, a Coda placed below and not centered on its symbol, a Fine with autoplace off offset one space
/// down. Each test measures a property against the staff, or against the same score with the property taken away.
@Suite("Marker and jump properties in layout")
struct NavigationPropertiesTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private static let tolerance: CGFloat = 0.01
    private static let owner = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func score() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("marker-properties"))
    }

    private static func layout(_ score: Score, showsInvisible: Bool = false) -> LayoutDocument {
        LayoutEngine.layout(
            score: score, options: ScoreViewOptions(wrapToViewWidth: false, showsInvisibleElements: showsInvisible),
            availableWidth: 2000,
        )
    }

    private static func bar(
        _ document: LayoutDocument, _ index: Int,
    ) throws -> (system: LayoutSystem, measure: LayoutMeasure) {
        let system = try #require(document.systems.first { $0.measures.contains { $0.measureIndex == index } })
        let measure = try #require(system.measures.first { $0.measureIndex == index })
        return (system, measure)
    }

    /// `score` with one bar changed — the control a property is measured against.
    private static func editing(_ score: Score, bar index: Int, _ edit: (inout Measure) -> Void) -> Score {
        var copy = score
        copy.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                edit(&staff.measures[index])
            }
        }
        return copy
    }

    private static func box(_ element: LayoutElement) throws -> CGRect {
        try #require(LayoutElementShape.navigationLabelRect(for: element))
    }

    private static func ink(_ element: LayoutElement, _ document: LayoutDocument) throws -> CGRect {
        try #require(TextInkGeometry.rects(for: element, metrics: document.metrics)?.first)
    }

    /// The left edge of the barline standing at a bar's start — the previous bar's end barline — in the bar's own
    /// coordinates: where a left marker without symbol centering starts (`NavigationPlacementTests.startBarLine`).
    private static func startBarLineMinX(_ document: LayoutDocument, bar index: Int) throws -> CGFloat {
        let (system, measure) = try bar(document, index)
        let previous = try #require(system.measures.first { $0.measureIndex == index - 1 })
        var bars: [(x: CGFloat, subtype: String?)] = []
        for element in previous.elements {
            if case let .barLine(subtype, origin, _, _, _) = element { bars.append((origin.x, subtype)) }
        }
        let rightmost = try #require(bars.max { $0.x < $1.x })
        let span = LayoutEngine.BarLineSpan(subtype: rightmost.subtype, originX: rightmost.x, sp: document.metrics.sp)
        return previous.origin.x - measure.origin.x + span.minX
    }

    /// Review Focus 6.
    @Test("a hidden To Coda draws nothing and takes no space or hit in print layout")
    func hiddenMarkDrawsNothing() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = try Self.score()
        let document = Self.layout(score)
        let measure = try Self.bar(document, 1).measure
        #expect(measure.markers.isEmpty && measure.invisibleElements.isEmpty)
        let without = Self.layout(Self.editing(score, bar: 1) { $0.markers = [] })
        #expect(document.systems.map(\.size) == without.systems.map(\.size))
        let target = ScoreHitTarget.marker(staff: Self.owner, measureIndex: 1, index: 0)
        #expect(ScoreHitTester(document: document).elementHitRect(for: target) == nil)
    }

    /// Review Focus 6: the same plan with the To Coda shown, a different one without it.
    @Test("a hidden To Coda still steers D.S. al Coda")
    func hiddenMarkStillPlays() throws {
        let score = try Self.score()
        let shown = Self.editing(score, bar: 1) { $0.markers[0].elementProperties.visible = true }
        let gone = Self.editing(score, bar: 1) { $0.markers = [] }
        func plan(_ score: Score) -> [Int] {
            RepeatUnwinder.plan(navigation: ScoreNavigation(score: score)).map(\.measureIndex)
        }
        #expect(plan(score) == plan(shown))
        #expect(plan(score) != plan(gone))
    }

    /// Review Focus 6.
    @Test("with invisible elements shown, the hidden To Coda is parked greyed and stays selectable")
    func hiddenMarkShownGreyed() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = try Self.score()
        let document = Self.layout(score, showsInvisible: true)
        let measure = try Self.bar(document, 1).measure
        #expect(measure.markers.isEmpty)
        let parked = measure.invisibleElements.filter { if case .marker = $0 { true } else { false } }
        #expect(parked.compactMap(\.elementID) == [.marker(staff: Self.owner, measureIndex: 1, index: 0)])
        let target = ScoreHitTarget.marker(staff: Self.owner, measureIndex: 1, index: 0)
        #expect(ScoreHitTester(document: document).elementHitRect(for: target) != nil)
    }

    @Test("a jump's offset moves its ink by exactly that many spaces across")
    func offsetMovesInk() throws {
        let score = try Self.score()
        let control = Self.editing(score, bar: 2) { $0.jumps[0].elementProperties.offset = nil }
        let document = Self.layout(score)
        let controlDocument = Self.layout(control)
        let jumps = try Self.bar(document, 2).measure.jumps
        let controlJumps = try Self.bar(controlDocument, 2).measure.jumps
        let moved = try Self.ink(#require(jumps.first), document)
        let placed = try Self.ink(#require(controlJumps.first), controlDocument)
        #expect(abs(moved.minX - (placed.minX - 2 * document.metrics.sp)) < Self.tolerance)
    }

    /// Autoplaced, the Fine would be lifted clear of the staff; with autoplace off it keeps its offset position,
    /// its bottom one space below the top line.
    @Test("a Fine with autoplace off stays where its offset puts it")
    func autoplaceOffKeepsPosition() throws {
        let document = try Self.layout(Self.score())
        let (system, measure) = try Self.bar(document, 4)
        let fine = try #require(measure.markers.first)
        let staffTop = try #require(system.staffOrigins.first).y
        let box = try Self.box(fine)
        #expect(abs(box.maxY - (staffTop + document.metrics.sp)) < Self.tolerance)
    }

    @Test("a Coda placed below stands under the staff, clear of it by the minimum distance")
    func belowPlacement() throws {
        let document = try Self.layout(Self.score())
        let (system, measure) = try Self.bar(document, 3)
        let coda = try #require(measure.markers.first)
        let staffBottom = try #require(system.staffOrigins.first).y + 4 * document.metrics.sp
        let box = try Self.box(coda)
        #expect(box.minY >= staffBottom + 0.5 * document.metrics.sp - Self.tolerance)
        #expect(box.minY <= staffBottom + 2 * document.metrics.sp)
    }

    /// The plan measured `ink.minX` against 0; Task 5 hangs a left marker from the start barline's left edge
    /// (`NavigationPlacementTests.wordsStartAtBarline`), so the expectation is that edge, not the bar's origin.
    @Test("a Coda with center-on-symbol off starts at its bar's start instead of centering its coda there")
    func centerOnSymbolOff() throws {
        let document = try Self.layout(Self.score())
        let markers = try Self.bar(document, 3).measure.markers
        let coda = try #require(markers.first)
        let ink = try Self.ink(coda, document)
        let barLineMinX = try Self.startBarLineMinX(document, bar: 3)
        #expect(abs(ink.minX - barLineMinX) < Self.tolerance)
    }

    @Test("a segno with its own music symbol size is set at that size")
    func musicSymbolSize() throws {
        let document = try Self.layout(Self.score())
        let markers = try Self.bar(document, 0).measure.markers
        let segno = try #require(markers.first)
        guard case let .marker(_, _, _, _, rich?, _, _) = segno else {
            Issue.record("a marker without runs")
            return
        }
        let run = try #require(rich.lines.first?.runs.first)
        #expect(abs(run.font.pointSize - 24 * document.metrics.sp / 5) < 1e-6)
    }

    @Test("layout hands the renderers each mark's color and side")
    func payloadCarriesColorAndSide() throws {
        let document = try Self.layout(Self.score())
        let jumps = try Self.bar(document, 2).measure.jumps
        let codas = try Self.bar(document, 3).measure.markers
        let fines = try Self.bar(document, 4).measure.markers
        guard case let .jump(_, _, _, _, color, jumpSide)? = jumps.first,
              case let .marker(_, _, _, _, _, _, codaSide)? = codas.first,
              case let .marker(_, _, _, _, _, _, fineSide)? = fines.first
        else {
            Issue.record("missing marks")
            return
        }
        #expect(color == ScoreColor(red: 200, green: 0, blue: 0))
        #expect(jumpSide == TextPlacementMetadata(side: .above, autoplace: true))
        #expect(codaSide == TextPlacementMetadata(side: .below, autoplace: true))
        #expect(fineSide == TextPlacementMetadata(side: .above, autoplace: false))
    }
}
