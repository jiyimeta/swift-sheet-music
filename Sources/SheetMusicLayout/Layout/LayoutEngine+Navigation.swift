#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// The horizontal extent of a barline's ink (`BarLineGeometry`), measure-local: `minX` is the left edge of its
    /// leftmost stroke or repeat dot, `maxX` the right edge of its rightmost stroke.
    struct BarLineSpan {
        let minX: CGFloat
        let maxX: CGFloat

        init(minX: CGFloat, maxX: CGFloat) {
            self.minX = minX
            self.maxX = maxX
        }

        /// A bar with no barline at the edge: a span of no width at `x`.
        init(at x: CGFloat) {
            minX = x
            maxX = x
        }

        init(subtype: String?, originX: CGFloat, sp: CGFloat) {
            minX = originX - BarLineGeometry.leftExtent(subtype: subtype, sp: sp)
            maxX = originX + BarLineGeometry.rightExtent(subtype: subtype, sp: sp)
        }

        var center: CGFloat {
            (minX + maxX) / 2
        }
    }

    /// The barlines a bar's marks hang from, in MuseScore's terms (`MarkerLayout::doLayoutMarker`,
    /// `markerlayout.cpp:66-131`; `TLayout::layoutJump`, `tlayout.cpp:3326-3328`): the barline ending the bar, which
    /// right markers and jumps align to, and the one standing at its start, which left markers align to — the previous
    /// bar's end barline, or this bar's start repeat.
    struct NavigationBarLines {
        let start: BarLineSpan
        let end: BarLineSpan

        init(start: BarLineSpan = BarLineSpan(at: 0), end: BarLineSpan) {
            self.start = start
            self.end = end
        }
    }

    /// The end barline among a bar's top-staff `elements`: the rightmost one standing near the bar's end. `nil` when
    /// the bar draws none there.
    static func endBarLine(in elements: [LayoutElement]?, contentWidth: CGFloat, sp: CGFloat) -> BarLineSpan? {
        var found: (x: CGFloat, subtype: String?)?
        for element in elements ?? [] {
            guard case let .barLine(subtype, origin, _, _, _) = element, origin.x > contentWidth - sp,
                  origin.x > (found?.x ?? -.infinity) else { continue }
            found = (origin.x, subtype)
        }
        return found.map { BarLineSpan(subtype: $0.subtype, originX: $0.x, sp: sp) }
    }

    /// The start barline of a bar: its own start repeat, else the previous bar's end barline (which stands just left
    /// of this bar's origin: the previous bar's full `width` back, the quantity the bars' X offsets accumulate), else
    /// none.
    ///
    /// A system's first bar gets none: MuseScore uses `measure->startBarLine()`'s width there
    /// (`markerlayout.cpp:84-87`, hence a hair of offset for a centered or left mark), but ssm draws no start barline
    /// element at a system's head (the staff's left edge carries none), so a zero-width span at the origin approximates
    /// it. `elements` and the previous bar's include hidden barlines, which MuseScore lays out with their width all the
    /// same.
    static func startBarLine(
        in elements: [LayoutElement]?, previous: (elements: [LayoutElement]?, width: CGFloat, contentWidth: CGFloat)?,
        sp: CGFloat,
    ) -> BarLineSpan {
        for element in elements ?? [] {
            if case let .barLine(subtype, origin, _, _, .startRepeat) = element, origin.x < sp {
                return BarLineSpan(subtype: subtype, originX: origin.x, sp: sp)
            }
        }
        guard let previous,
              let end = endBarLine(in: previous.elements, contentWidth: previous.contentWidth, sp: sp)
        else { return BarLineSpan(at: 0) }
        return BarLineSpan(minX: end.minX - previous.width, maxX: end.maxX - previous.width)
    }

    /// A bar's markers, then its jumps, set the way MuseScore sets repeat text and emitted into the top staff's pass-1
    /// buffer — X measure-local, Y staff-local with the top line at `sp * 2` — where `SkylineAutoplacePass` places
    /// them above the staff, last of everything, as `SystemLayout::layoutSystemElements` does (`markersAndJumps`,
    /// `rendering/score/systemlayout.cpp:1360-1362`).
    ///
    /// Each block starts with its bottom on the top line and is lifted from there: MuseScore starts a repeat text's
    /// baseline on the top line (`AlignV::BASELINE`, `TextLayout::layoutBaseTextBase1`, `textlayout.cpp:111-119`) and
    /// `Autoplace::autoplaceMeasureElement` pushes it clear by `Sid::repeatMinDistance`, 0.5 sp.
    static func navigationElements(
        for measure: Measure, measureIndex: Int, staff: StaffAddress, contentWidth: CGFloat, metrics: StaffMetrics,
        barLines: NavigationBarLines? = nil,
    ) -> [LayoutElement] {
        let barLines = barLines ?? NavigationBarLines(end: BarLineSpan(at: contentWidth))
        let markers = measure.markers.enumerated().map { index, marker in
            markerElement(
                marker, metrics: metrics, barLines: barLines,
                identity: .marker(staff: staff, measureIndex: measureIndex, index: index),
            )
        }
        let jumps = measure.jumps.enumerated().map { index, jump in
            jumpElement(
                jump, metrics: metrics, barLines: barLines,
                identity: .jump(staff: staff, measureIndex: measureIndex, index: index),
            )
        }
        return markers + jumps
    }

    /// `MarkerLayout::doLayoutMarker` (`rendering/score/markerlayout.cpp:66-105`): a right marker hangs from its bar's
    /// end, a left one from its start; one holding a segno or coda puts that symbol's center on the barline
    /// (`centerOnSymbol`, then `computeCustomTextOffset`), any other puts its own aligned edge there. The barline is
    /// the one standing there, with its real width: MuseScore moves a centered mark by half of it and a left-aligned
    /// one by all of it (`xAdj -= blWidth / 2`, `xAdj -= blWidth`, `:97-100`), and a right-aligned one ends at the
    /// bar's width, which holds the barline — so a final or end-repeat barline's thick stroke is cleared.
    private static func markerElement(
        _ marker: Marker, metrics: StaffMetrics, barLines: NavigationBarLines, identity: ScoreElementID,
    ) -> LayoutElement {
        let displayed = marker.displayedRichText
        let isRight = marker.kind.isRightMarker
        let rich = LayoutRichText(marker: displayed, style: isRight ? .repeatRight : .repeatLeft, metrics: metrics)
        let anchor = LayoutRichText.anchor(for: .forMarker(marker.kind))
        let width = rich.ink?.width ?? 0
        let barLine = isRight ? barLines.end : barLines.start
        let left: CGFloat
        if let symbolX = rich.repeatSymbolX(anchor: anchor) {
            left = barLine.center - symbolX
        } else {
            left = isRight ? barLine.maxX - width : barLine.minX
        }
        return .marker(
            kind: marker.kind, text: displayed.plainText,
            origin: CGPoint(x: left + anchor.x * width, y: metrics.sp * 2),
            identity: identity, richText: rich,
        )
    }

    /// `TLayout::layoutJump` (`rendering/score/tlayout.cpp:3316-3349`): right-aligned on its bar's end barline's right
    /// edge — `bl->segment()->x() + bl->ldata()->bbox().width()` (`:3328`).
    private static func jumpElement(
        _ jump: Jump, metrics: StaffMetrics, barLines: NavigationBarLines, identity: ScoreElementID,
    ) -> LayoutElement {
        let rich = LayoutRichText(jump.displayedRichText, style: .repeatRight, metrics: metrics)
        let anchor = LayoutRichText.anchor(for: .jump)
        let width = rich.ink?.width ?? 0
        return .jump(
            text: jump.text,
            origin: CGPoint(x: barLines.end.maxX - width + anchor.x * width, y: metrics.sp * 2),
            identity: identity, richText: rich,
        )
    }
}
