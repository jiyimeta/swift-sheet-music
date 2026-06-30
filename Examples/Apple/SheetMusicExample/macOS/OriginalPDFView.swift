#if os(macOS)
    import AppKit
    import PDFKit
    import SheetMusicCore
    import SheetMusicPDF
    import SwiftUI

    /// Displays the ORIGINAL imported PDF (PDFKit) with a playback-cursor
    /// overlay and click-to-seek, driven by `PDFScoreGeometry`. Distinct from
    /// `MagnifyingPDFScrollView`, which shows this app's RE-ENGRAVED layout.
    ///
    /// The cursor is a translucent PDF annotation placed in page coordinates —
    /// the same space `PDFScoreGeometry` reports — so PDFKit handles all
    /// zoom / scroll transforms for free. A click is converted to a page +
    /// page-point and resolved to a `ScoreItemID` via `geometry.hitTest`.
    @available(macOS 15.0, *)
    struct OriginalPDFView: NSViewRepresentable {
        let document: PDFDocument
        let geometry: PDFScoreGeometry
        let score: Score
        /// Current playback cursor (drives the overlay). `nil` hides it.
        let cursor: ScoreCursor?
        /// Bring the cursor into view when it lands off-screen.
        let followsCursor: Bool
        /// Resolved tap target (or `nil` for empty space).
        let onTap: (ScoreItemID?) -> Void

        func makeNSView(context: Context) -> PDFView {
            let view = ClickablePDFView()
            view.document = document
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
            view.backgroundColor = NSColor(white: 0.92, alpha: 1)
            view.onClick = { [weak coordinator = context.coordinator] point in
                coordinator?.handleClick(at: point)
            }
            context.coordinator.pdfView = view
            return view
        }

        func updateNSView(_ view: PDFView, context: Context) {
            context.coordinator.parent = self
            if view.document !== document {
                view.document = document
            }
            context.coordinator.applyCursor(cursor)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        @MainActor
        final class Coordinator {
            var parent: OriginalPDFView
            weak var pdfView: PDFView?
            private var active: (page: PDFPage, annotation: PDFAnnotation)?

            init(_ parent: OriginalPDFView) {
                self.parent = parent
            }

            /// Resolve a click (PDFView coords) to a `ScoreItemID` and report.
            func handleClick(at viewPoint: CGPoint) {
                guard let pdfView, let document = pdfView.document,
                      let page = pdfView.page(for: viewPoint, nearest: true)
                else {
                    parent.onTap(nil)
                    return
                }
                let pagePoint = pdfView.convert(viewPoint, to: page)
                let pageIndex = document.index(for: page)
                parent.onTap(parent.geometry.hitTest(
                    pageIndex: pageIndex, point: pagePoint,
                ))
            }

            /// Move / draw / clear the cursor annotation for `cursor`.
            func applyCursor(_ cursor: ScoreCursor?) {
                guard let pdfView, let document = pdfView.document else { return }
                clearActive()
                guard let cursor,
                      let rect = parent.geometry.cursorRect(for: cursor, in: parent.score),
                      let page = document.page(at: rect.pageIndex)
                else { return }
                let annotation = PDFAnnotation(
                    bounds: rect.rect, forType: .square, withProperties: nil,
                )
                annotation.color = NSColor.systemBlue.withAlphaComponent(0.35)
                annotation.interiorColor = NSColor.systemBlue.withAlphaComponent(0.15)
                page.addAnnotation(annotation)
                active = (page, annotation)
                if parent.followsCursor {
                    scrollIntoView(rect: rect.rect, on: page, pdfView: pdfView)
                }
            }

            private func clearActive() {
                if let active {
                    active.page.removeAnnotation(active.annotation)
                }
                active = nil
            }

            /// Scroll only when the cursor rect isn't already fully visible.
            private func scrollIntoView(
                rect: CGRect, on page: PDFPage, pdfView: PDFView,
            ) {
                let inView = pdfView.convert(rect, from: page)
                guard let docView = pdfView.documentView else { return }
                let visible = docView.convert(docView.visibleRect, to: pdfView)
                if !visible.contains(inView) {
                    pdfView.go(to: rect, on: page)
                }
            }
        }
    }

    /// PDFView that reports a left-click as a point in its own coordinate
    /// space, bypassing the default text/annotation selection so a click is a
    /// clean seek gesture. Scroll / zoom are unaffected (trackpad / scrollers).
    @available(macOS 15.0, *)
    private final class ClickablePDFView: PDFView {
        var onClick: ((CGPoint) -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onClick?(point)
        }
    }
#endif
