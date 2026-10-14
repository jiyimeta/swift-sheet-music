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
    ) -> Found? {
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
        var measures = (0 ..< 2).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
        measures[bar].markers = markers
        measures[bar].jumps = jumps
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

    private static func box(_ element: LayoutElement) throws -> CGRect {
        try #require(LayoutElementShape.navigationLabelRect(for: element))
    }

    private static func ink(_ element: LayoutElement, _ found: Found) throws -> CGRect {
        try #require(TextInkGeometry.rects(for: element, metrics: found.document.metrics)?.first)
    }

    /// The ink center x of the marker's first symbol run, measure-local.
    private static func symbolCenterX(_ element: LayoutElement) throws -> CGFloat {
        guard case let .marker(kind, _, origin, _, rich?) = element else {
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
        #expect(abs(ink.maxX - found.measure.width) < Self.tolerance)
        let staffTop = try #require(found.system.staffOrigins.first).y
        let box = try Self.box(jump)
        #expect(box.maxY <= staffTop - found.document.metrics.sp * 0.5 + Self.tolerance)
    }

    @Test("a segno is centered on its bar's start barline")
    func segnoCenteredOnStartBarline() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .segno)]))
        let segno = try #require(found.measure.markers.first)
        let center = try Self.symbolCenterX(segno)
        #expect(abs(center) < Self.tolerance)
    }

    @Test(
        "a right marker ends on its bar's end barline",
        arguments: [Marker.Kind.fine, .toCoda, .daCoda, .daDoubleCoda],
    )
    func rightMarkerEndsAtBarline(kind: Marker.Kind) throws {
        let found = try #require(Self.layout(markers: [Marker(kind: kind)]))
        let marker = try #require(found.measure.markers.first)
        let ink = try Self.ink(marker, found)
        #expect(abs(ink.maxX - found.measure.width) < Self.tolerance)
    }

    @Test("To ⟨coda⟩ centers its coda on the end barline")
    func toCodaSymCentersCoda() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .toCodaSym)]))
        let marker = try #require(found.measure.markers.first)
        let center = try Self.symbolCenterX(marker)
        #expect(abs(center - found.measure.width) < Self.tolerance)
    }

    @Test("a left marker of words starts at its bar's start")
    func wordsStartAtBarline() throws {
        let found = try #require(Self.layout(markers: [Marker(kind: .user, text: "Solo")]))
        let marker = try #require(found.measure.markers.first)
        let ink = try Self.ink(marker, found)
        #expect(abs(ink.minX) < Self.tolerance)
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
