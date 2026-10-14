#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// Markers and jumps where MuseScore puts them (`MarkerLayout::doLayoutMarker`, `TLayout::layoutJump`): a right
/// marker or a jump ends at its bar's end barline, a left marker starts at its bar's start, and one holding a segno or
/// coda centers that symbol on the barline — all above the staff, lifted clear of whatever is there, last of
/// everything (`systemlayout.cpp:1360-1362`). Measured with the installed provider: relations within 0.01 pt.
@Suite("Marker and jump placement")
struct NavigationPlacementTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let tolerance: CGFloat = 0.01

    private struct Found {
        let document: LayoutDocument
        let system: LayoutSystem
        let measure: LayoutMeasure
    }

    /// Two whole-note bars; `markers`, `jumps` and staff `texts` go on bar `bar` (default the second, so its start
    /// barline is a real one and its end barline the final one).
    private static func layout(
        markers: [Marker] = [], jumps: [Jump] = [], texts: [StaffText] = [], bar: Int = 1,
        endRepeat: Bool = false, pitch: Int = 72,
    ) -> Found? {
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: pitch, tpc: 14)]))
        var measures = (0 ..< 2).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        measures[bar].markers = markers
        measures[bar].jumps = jumps
        if endRepeat { measures[bar].endRepeatCount = 2 }
        var lanes = (0 ..< 2).map { _ in SystemMeasure() }
        lanes[bar] = SystemMeasure(elements: texts.map {
            PositionedSystemElement(position: .start, element: .staffText($0), originalStaff: staff)
        })
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: measures)],
        )], systemMeasures: IdentifiedArray(lanes))
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
        guard let system = document.systems.first,
              let measure = system.measures.first(where: { $0.measureIndex == bar }) else { return nil }
        return Found(document: document, system: system, measure: measure)
    }

    /// The ink span of a measure's end barline (its rightmost barline element), measure-local: what MuseScore's
    /// `bl->segment()->x() + bl->ldata()->bbox().width()` reaches (`tlayout.cpp:3328`), and the barline's origin.
    private static func endBarLine(_ found: Found) throws -> (originX: CGFloat, span: LayoutEngine.BarLineSpan) {
        var bars: [(x: CGFloat, subtype: String?)] = []
        for element in found.measure.elements {
            if case let .barLine(subtype, origin, _, _, _) = element { bars.append((origin.x, subtype)) }
        }
        let rightmost = bars.max { $0.x < $1.x }
        let bar = try #require(rightmost)
        let span = LayoutEngine.BarLineSpan(subtype: bar.subtype, originX: bar.x, sp: found.document.metrics.sp)
        return (bar.x, span)
    }

    /// The ink span of the barline standing at the bar's start, measure-local: the previous bar's end barline, or none
    /// (a span of no width at 0) on a system's first bar.
    private static func startBarLine(_ found: Found) throws -> (minX: CGFloat, center: CGFloat) {
        guard let previous = found.system.measures.first(where: { $0.measureIndex == found.measure.measureIndex - 1 })
        else { return (0, 0) }
        let span = try endBarLine(Found(document: found.document, system: found.system, measure: previous)).span
        let shift = previous.origin.x - found.measure.origin.x
        return (shift + span.minX, shift + span.center)
    }

    private static func startBarLineCenter(_ found: Found) throws -> CGFloat {
        try startBarLine(found).center
    }

    private static func box(_ element: LayoutElement) throws -> CGRect {
        try #require(LayoutElementShape.navigationLabelRect(for: element))
    }

    private static func ink(_ element: LayoutElement, _ found: Found) throws -> CGRect {
        try #require(TextInkGeometry.rects(for: element, metrics: found.document.metrics)?.first)
    }

    /// The ink center x of the marker's first symbol run, measure-local.
    private static func symbolCenterX(_ element: LayoutElement) throws -> CGFloat {
        guard case let .marker(kind, _, origin, _, rich?, _, _) = element else {
            Issue.record("not a marker with runs")
            return .nan
        }
        let placed = rich.positionedRuns(at: origin, anchor: LayoutRichText.anchor(for: .forMarker(kind)))
        let symbol = placed.first { if case .symbol = $0.content { true } else { false } }
        let run = try #require(symbol)
        let ink = try #require(FontMetrics.provider.textInkBounds(text: run.content.string, font: run.font))
        return run.baseline.x + ink.midX
    }

    @Test("a jump ends on its bar's end barline, above the staff — not past the final barline (W1 QA)")
    func jumpEndsAtBarline() throws {
        let found = try #require(Self.layout(jumps: [Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")]))
        let jump = try #require(found.measure.jumps.first)
        let ink = try Self.ink(jump, found)
        let barLine = try Self.endBarLine(found)
        #expect(abs(ink.maxX - barLine.span.maxX) < Self.tolerance)
        let staffTop = try #require(found.system.staffOrigins.first).y
        let box = try Self.box(jump)
        #expect(box.maxY <= staffTop - found.document.metrics.sp * 0.5 + Self.tolerance)
    }

    /// `bl->segment()->x() + bl->ldata()->bbox().width()` (`tlayout.cpp:3328`): the barline's RIGHT edge, so a jump on
    /// a final or an end-repeat barline clears its thick stroke instead of ending on the thin one.
    @Test("a jump on a final or end-repeat barline ends at the barline's right edge", arguments: [false, true])
    func jumpClearsThickBarline(endRepeat: Bool) throws {
        let found = try #require(Self.layout(
            jumps: [Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")],
            bar: endRepeat ? 0 : 1, endRepeat: endRepeat,
        ))
        let jump = try #require(found.measure.jumps.first)
        let ink = try Self.ink(jump, found)
        let barLine = try Self.endBarLine(found)
        let thickStrokeReach = found.document.metrics.sp * 0.2
        #expect(barLine.span.maxX - barLine.originX > thickStrokeReach)
        #expect(abs(ink.maxX - barLine.span.maxX) < Self.tolerance)
    }

    @Test("a segno is centered on its bar's start barline")
    func segnoCenteredOnStartBarline() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .segno)]))
        let segno = try #require(found.measure.markers.first)
        let center = try Self.symbolCenterX(segno)
        let barLineCenter = try Self.startBarLineCenter(found)
        #expect(abs(center - barLineCenter) < Self.tolerance)
    }

    /// The bar's X offsets accumulate its full `width`, courtesy band included, so the previous bar's end barline
    /// stands `width` — not `contentWidth` — left of the next bar's origin. A courtesy only ever ends a system, so
    /// no laid-out bar has a previous one with a band; the rule is pinned on hand-built elements.
    @Test("the start barline stands a full previous width back, a courtesy band included")
    func startBarLineUsesPreviousWidth() {
        let sp: CGFloat = 7
        let originX: CGFloat = 100 - sp / 2
        let bar = LayoutElement.barLine(
            subtype: nil, origin: CGPoint(x: originX, y: 0), halfHeight: 14, measureIndex: 0, role: .trailing,
        )
        let span = LayoutEngine.startBarLine(
            in: [], previous: (elements: [bar], width: 130, contentWidth: 100), sp: sp,
        )
        let expected = LayoutEngine.BarLineSpan(subtype: nil, originX: originX - 130, sp: sp)
        #expect(abs(span.minX - expected.minX) < Self.tolerance)
        #expect(abs(span.maxX - expected.maxX) < Self.tolerance)
    }

    /// `MarkerLayout::doLayoutMarker` lifts a mark clear of what stands under it — a note far above the staff
    /// included (`Autoplace::autoplaceMeasureElement`, `autoplace.cpp:128-200`).
    @Test("a marker above a tall note is lifted clear of it")
    func markerClearsTallNote() throws {
        let found = try #require(Self.layout(
            markers: [Marker(kind: .user, text: String(repeating: "Maestoso ", count: 12))], pitch: 100,
        ))
        let marker = try #require(found.measure.markers.first)
        let box = try Self.box(marker)
        let chordElement = found.measure.elements.first { if case .chord = $0 { true } else { false } }
        let chord = try #require(chordElement)
        let noteTop = try #require(LayoutEngine.elementYPoints(chord).min())
        #expect(box.maxY <= noteTop - found.document.metrics.sp * 0.5 + Self.tolerance)
    }

    @Test(
        "a right marker ends on its bar's end barline",
        arguments: [Marker.Kind.fine, .toCoda, .daCoda, .daDoubleCoda],
    )
    func rightMarkerEndsAtBarline(kind: Marker.Kind) throws {
        let found = try #require(Self.layout(markers: [Marker(kind: kind)]))
        let marker = try #require(found.measure.markers.first)
        let ink = try Self.ink(marker, found)
        let barLine = try Self.endBarLine(found)
        #expect(abs(ink.maxX - barLine.span.maxX) < Self.tolerance)
    }

    @Test("To ⟨coda⟩ centers its coda on the end barline")
    func toCodaSymCentersCoda() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .toCodaSym)]))
        let marker = try #require(found.measure.markers.first)
        let center = try Self.symbolCenterX(marker)
        let barLine = try Self.endBarLine(found)
        #expect(abs(center - barLine.span.center) < Self.tolerance)
    }

    @Test("a left marker of words starts at its bar's start barline")
    func wordsStartAtBarline() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .user, text: "Solo")]))
        let marker = try #require(found.measure.markers.first)
        let ink = try Self.ink(marker, found)
        let barLine = try Self.startBarLine(found)
        // The barline's LEFT edge, not its center: they differ by half its stroke, which the tolerance excludes.
        #expect(abs(ink.minX - barLine.minX) < Self.tolerance)
        #expect(abs(barLine.center - barLine.minX) > Self.tolerance)
    }

    /// Review Focus 5.
    @Test("two markers in one bar stack instead of overlapping")
    func markersStack() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .segno), Marker(kind: .coda)]))
        try #require(found.measure.markers.count == 2)
        let first = try Self.box(found.measure.markers[0])
        let second = try Self.box(found.measure.markers[1])
        #expect(second.maxY <= first.minY + Self.tolerance)
    }

    /// Review Focus 5.
    @Test("a Fine and its D.C. al Fine both end on the barline, the jump above the marker")
    func fineAndItsJump() throws {
        let found = try #require(Self.layout(
            markers: [Marker(kind: .fine)], jumps: [Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")],
        ))
        let fineElement = try #require(found.measure.markers.first)
        let jumpElement = try #require(found.measure.jumps.first)
        let fine = try Self.box(fineElement)
        let jump = try Self.box(jumpElement)
        #expect(jump.maxY <= fine.minY + Self.tolerance)
    }

    /// Review Focus 5 — the W1 QA finding: a mark and a staff text at the bar's start.
    @Test("a marker clears a staff text at its bar's start instead of overlapping it")
    func markerClearsStaffText() throws {
        let found = try #require(Self.layout(
            markers: [Marker(kind: .coda, text: "Coda")], texts: [StaffText(text: "senza Ped.")],
        ))
        let markerElement = try #require(found.measure.markers.first)
        let marker = try Self.box(markerElement)
        let staffText = found.measure.elements.first { if case .staffText = $0 { true } else { false } }
        let textElement = try #require(staffText)
        let boxes = LayoutElementShape.autoplacedRects(
            for: textElement, kind: .staffText, metrics: found.document.metrics,
        )
        let text = try #require(boxes.first)
        #expect(marker.maxY <= text.minY + Self.tolerance)
    }

    /// Review Focus 4.
    @Test("a segno on a system's first bar hangs half over the system's left edge, unclamped, inside the system")
    func segnoAtSystemStart() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .segno)], bar: 0))
        let segno = try #require(found.measure.markers.first)
        let center = try Self.symbolCenterX(segno)
        #expect(abs(center) < Self.tolerance)
        let box = try Self.box(segno)
        #expect(box.minX < 0)
        #expect(box.minY >= -Self.tolerance)
    }

    /// Review Focus 4.
    @Test("a mark's Y points reach its box's top, so the system reserves what autoplace lifts")
    func yPointsSpanTheBox() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .segno), Marker(kind: .coda)]))
        for element in found.measure.markers {
            let top = try Self.box(element).minY
            let points = LayoutEngine.elementYPoints(element)
            let reachesTop = points.contains { abs($0 - top) < Self.tolerance }
            #expect(reachesTop)
        }
    }
}
