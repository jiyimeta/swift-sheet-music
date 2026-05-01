#if !os(macOS)
    import SheetMusic
    import SheetMusicPDF
    import SheetMusicUI
    import SwiftUI

    /// On-screen PDF preview with pinch-to-zoom on iOS. Mirrors the
    /// page deck the share-button export produces — same geometry,
    /// same break-indicator overlays — so the preview is a truthful
    /// proxy for the exported PDF.
    @available(iOS 16.0, *)
    struct PDFPreviewView: View {
        let doc: LayoutDocument
        let pages: [PDFExporter.PageBatch]
        let page: EngravingPage
        /// Committed magnification driving each `PDFPageView`'s
        /// `renderScale` (so glyphs stay vector-sharp). The parent
        /// owns this so zoom level survives mode switches.
        @Binding var pdfScale: CGFloat

        /// Live overlay scale applied via `scaleEffect` during an active
        /// pinch — cheap visual upscale that avoids re-rasterising every
        /// page Canvas at gesture frame rate. Always 1.0 outside a
        /// pinch; on gesture end we fold it into `pdfScale` (which
        /// drives the Canvas's true `renderScale`) so the result is
        /// vector-sharp once the user releases.
        @State private var pdfGestureScale: CGFloat = 1.0

        var body: some View {
            let pageSize = page.size
            let pageSpacing: CGFloat = 16 * pdfScale
            let outerPadding: CGFloat = 16 * pdfScale
            let labelHeight: CGFloat = 14 * pdfScale + 6 * pdfScale
            let naturalWidth =
                pageSize.width * pdfScale * CGFloat(pages.count)
                + pageSpacing * CGFloat(max(0, pages.count - 1))
                + outerPadding * 2
            let naturalHeight =
                pageSize.height * pdfScale + labelHeight
                    + outerPadding * 2

            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: pageSpacing) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, batch in
                        VStack(spacing: 6 * pdfScale) {
                            // PDFPageView's `renderScale` makes the
                            // Canvas draw glyphs at the new resolution
                            // — vector-sharp instead of an upscaled
                            // bitmap. We only update it on gesture-end
                            // (committed `pdfScale`); during the active
                            // pinch the cheap `scaleEffect` overlay
                            // handles motion smoothly.
                            PDFPageView(
                                systems: batch.systems,
                                pageStartY: batch.startY,
                                titleFrame: idx == 0 ? doc.titleFrame : nil,
                                metrics: doc.metrics,
                                pageSize: pageSize,
                                margins: page.margins(forPageIndex: idx),
                                renderScale: pdfScale,
                                showBreakIndicators: true
                            )
                            .background(Color.white)
                            .border(Color.gray.opacity(0.4))
                            .shadow(radius: 3 * pdfScale)
                            Text("\(idx + 1) / \(pages.count)")
                                .font(.system(size: 11 * pdfScale))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(outerPadding)
                // Apply the gesture overlay AFTER padding so the whole
                // page deck zooms uniformly. `scaleEffect` is visual-
                // only; the explicit frame tells the parent ScrollView
                // the scaled extent so it can scroll the full zoomed
                // area during the gesture.
                .scaleEffect(pdfGestureScale, anchor: .topLeading)
                .frame(
                    width: naturalWidth * pdfGestureScale,
                    height: naturalHeight * pdfGestureScale,
                    alignment: .topLeading
                )
            }
            .background(Color(white: 0.92))
            .gesture(
                MagnificationGesture()
                    .onChanged { rawValue in
                        let target = pdfScale * rawValue
                        let clamped = max(0.25, min(4.0, target))
                        pdfGestureScale = clamped / pdfScale
                    }
                    .onEnded { _ in
                        pdfScale = max(
                            0.25, min(4.0, pdfScale * pdfGestureScale)
                        )
                        pdfGestureScale = 1
                    })
        }
    }
#endif
