#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
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
    ) -> [LayoutElement] {
        let markers = measure.markers.enumerated().map { index, marker in
            markerElement(
                marker, contentWidth: contentWidth, metrics: metrics,
                identity: .marker(staff: staff, measureIndex: measureIndex, index: index),
            )
        }
        let jumps = measure.jumps.enumerated().map { index, jump in
            jumpElement(
                jump, contentWidth: contentWidth, metrics: metrics,
                identity: .jump(staff: staff, measureIndex: measureIndex, index: index),
            )
        }
        return markers + jumps
    }

    /// `MarkerLayout::doLayoutMarker` (`rendering/score/markerlayout.cpp`): a right marker hangs from its bar's end, a
    /// left one from its start; one holding a segno or coda puts that symbol's center on the barline (`centerOnSymbol`,
    /// then `computeCustomTextOffset`), any other puts its own aligned edge there. The barline's own width, which
    /// MuseScore allows for, is a fraction of a space and is ignored.
    private static func markerElement(
        _ marker: Marker, contentWidth: CGFloat, metrics: StaffMetrics, identity: ScoreElementID,
    ) -> LayoutElement {
        let displayed = marker.displayedRichText
        let isRight = marker.kind.isRightMarker
        let rich = LayoutRichText(marker: displayed, style: isRight ? .repeatRight : .repeatLeft, metrics: metrics)
        let anchor = LayoutRichText.anchor(for: .forMarker(marker.kind))
        let width = rich.ink?.width ?? 0
        let onBarline = rich.repeatSymbolX(anchor: anchor) ?? (isRight ? width : 0)
        let left = (isRight ? contentWidth : 0) - onBarline
        return .marker(
            kind: marker.kind, text: displayed.plainText,
            origin: CGPoint(x: left + anchor.x * width, y: metrics.sp * 2),
            identity: identity, richText: rich,
        )
    }

    /// `TLayout::layoutJump` (`rendering/score/tlayout.cpp:3316-3349`): right-aligned on its bar's end barline.
    private static func jumpElement(
        _ jump: Jump, contentWidth: CGFloat, metrics: StaffMetrics, identity: ScoreElementID,
    ) -> LayoutElement {
        let rich = LayoutRichText(jump.displayedRichText, style: .repeatRight, metrics: metrics)
        let anchor = LayoutRichText.anchor(for: .jump)
        let width = rich.ink?.width ?? 0
        return .jump(
            text: jump.text,
            origin: CGPoint(x: contentWidth - width + anchor.x * width, y: metrics.sp * 2),
            identity: identity, richText: rich,
        )
    }
}
