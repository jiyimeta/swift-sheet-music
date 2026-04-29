import SheetMusicCore
import SheetMusicLayout
import SheetMusicUI
import SwiftUI

/// One page of a paginated `LayoutDocument`. Re-uses
/// `ScoreCanvasDrawing.drawSystem` from `SheetMusicUI` so the PDF
/// uses the exact same glyph / staff / spanner pipeline as the
/// on-screen `ScoreView` — vector output, no separate code path to
/// drift over time.
///
/// The view's coordinate space is the page in points (1pt = 1/72").
/// The `Canvas` is set up so that document-space `(0, pageStartY)`
/// maps to page-space `(margins.leading, margins.top)`. Each system
/// on the page is then drawn in document coords; the single
/// translation handles both the inset margin and the per-page Y
/// offset.
@available(macOS 15.0, iOS 16.0, *)
public struct PDFPageView: View {
    let systems: [LayoutSystem]
    let pageStartY: CGFloat
    /// Title block for this page, when present. Only page 1 of a
    /// score with a leading `<VBox>` carries one; other pages pass
    /// `nil`.
    let titleFrame: LayoutTitleFrame?
    let metrics: StaffMetrics
    let pageSize: CGSize
    let margins: PageMargins
    /// Visual zoom factor for previewers. The view's frame becomes
    /// `pageSize * renderScale` and the `Canvas` scales its drawing
    /// coordinates by the same factor — so glyphs and lines stay
    /// vector-sharp at any zoom level instead of being upscaled
    /// bitmap pixels (which `scaleEffect` would do). PDF export
    /// uses `1.0`; the on-screen preview pinch-zoom drives this
    /// directly.
    let renderScale: CGFloat
    /// Whether to overlay MuseScore-style break indicator badges.
    /// On-screen previews pass `true` for authoring affordance;
    /// `PDFExporter.export` passes `false` so the saved file is
    /// indicator-free.
    let showBreakIndicators: Bool

    public init(
        systems: [LayoutSystem],
        pageStartY: CGFloat,
        titleFrame: LayoutTitleFrame? = nil,
        metrics: StaffMetrics,
        pageSize: CGSize,
        margins: PageMargins,
        renderScale: CGFloat = 1,
        showBreakIndicators: Bool = false
    ) {
        self.systems = systems
        self.pageStartY = pageStartY
        self.titleFrame = titleFrame
        self.metrics = metrics
        self.pageSize = pageSize
        self.margins = margins
        self.renderScale = renderScale
        self.showBreakIndicators = showBreakIndicators
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas(opaque: true) { context, _ in
                // White background — `opaque: true` doesn't
                // auto-clear, and we want a paper-like fill
                // regardless of the host platform's default canvas
                // color. Fill the full (scaled) canvas extent so
                // the background still covers the view at any
                // `renderScale`.
                let canvasSize = CGSize(
                    width: pageSize.width * renderScale,
                    height: pageSize.height * renderScale)
                context.fill(
                    Path(CGRect(origin: .zero, size: canvasSize)),
                    with: .color(.white))
                var local = context
                // Scale the drawing coordinates BEFORE translating
                // so glyphs render at native resolution at the new
                // size, not as an upscaled bitmap.
                if renderScale != 1 {
                    local.scaleBy(x: renderScale, y: renderScale)
                }
                local.translateBy(
                    x: margins.leading,
                    y: margins.top - pageStartY)
                if let titleFrame {
                    TitleFrameRenderer.draw(titleFrame, into: &local)
                }
                for system in systems {
                    ScoreCanvasDrawing.drawSystem(
                        system, metrics: metrics, into: &local)
                }
            }
            if showBreakIndicators {
                BreakIndicatorOverlay(
                    mode: .document(
                        systems: systems,
                        documentYOffset: pageStartY - margins.top,
                        xOffset: margins.leading),
                    metrics: metrics)
                    .scaleEffect(renderScale, anchor: .topLeading)
            }
        }
        .frame(
            width: pageSize.width * renderScale,
            height: pageSize.height * renderScale)
        .environment(\.colorScheme, .light)
    }
}
