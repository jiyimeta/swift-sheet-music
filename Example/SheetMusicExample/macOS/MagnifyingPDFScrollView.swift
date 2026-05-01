#if os(macOS)
    import AppKit
    import SheetMusic
    import SheetMusicPDF
    import SheetMusicUI
    import SwiftUI

    /// Hosts the PDF page deck inside an `NSScrollView` whose
    /// `allowsMagnification` does the heavy lifting. AppKit re-
    /// rasterises the document layer at the current magnification —
    /// SwiftUI Canvas drawings stay vector-sharp at any zoom level
    /// without us having to redraw them per pinch frame, exactly the
    /// way horizontal mode keeps the score sharp during pinch.
    @available(macOS 15.0, *)
    struct MagnifyingPDFScrollView: NSViewRepresentable {
        @Binding var magnification: CGFloat
        let doc: LayoutDocument
        let pages: [PDFExporter.PageBatch]
        let page: EngravingPage

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.allowsMagnification = true
            scrollView.minMagnification = 0.25
            scrollView.maxMagnification = 4.0
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.usesPredominantAxisScrolling = false
            scrollView.drawsBackground = true
            scrollView.backgroundColor = NSColor(white: 0.92, alpha: 1)

            let hosting = NSHostingView(rootView: rootView)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            scrollView.documentView = hosting

            scrollView.magnification = magnification
            context.coordinator.binding = $magnification
            context.coordinator.lastDocId = ObjectIdentifier(
                doc.systems as AnyObject)

            // NSScrollView fires `didEndLiveMagnify` once after the
            // gesture settles; we mirror its final value into the
            // SwiftUI binding so a future external write (e.g. a
            // "Reset zoom" button) can apply.
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.magnificationDidEnd(_:)),
                name: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.willStartLiveMagnify(_:)),
                name: NSScrollView.willStartLiveMagnifyNotification,
                object: scrollView
            )

            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            context.coordinator.binding = $magnification
            // Rebuild the rootView only when the cached layout actually
            // changed — body re-evals during scroll / magnify shouldn't
            // walk the whole page deck again.
            let newDocId = ObjectIdentifier(doc.systems as AnyObject)
            if context.coordinator.lastDocId != newDocId
                || context.coordinator.lastPageCount != pages.count
            {
                (nsView.documentView as? NSHostingView<AnyView>)?
                    .rootView = rootView
                context.coordinator.lastDocId = newDocId
                context.coordinator.lastPageCount = pages.count
            }
            // Apply external magnification writes (e.g. a sidebar
            // reset). Skip while the user is mid-pinch — writing back
            // during a live gesture would fight AppKit's own update.
            if !context.coordinator.isLiveMagnifying
                && abs(nsView.magnification - magnification) > 0.001
            {
                nsView.magnification = magnification
            }
        }

        private var rootView: AnyView {
            let pageSize = page.size
            return AnyView(
                HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, batch in
                        VStack(spacing: 6) {
                            // Layer-tree page (vector CAShapeLayers) so
                            // NSScrollView's `allowsMagnification` re-
                            // rasterises the contents at the new scale
                            // — sharp throughout the pinch, exactly like
                            // horizontal mode's score view.
                            PDFPageLayerView(
                                systems: batch.systems,
                                pageStartY: batch.startY,
                                titleFrame: idx == 0 ? doc.titleFrame : nil,
                                metrics: doc.metrics,
                                pageSize: pageSize,
                                margins: page.margins(forPageIndex: idx)
                            )
                            .frame(
                                width: pageSize.width,
                                height: pageSize.height
                            )
                            // Authoring overlay: line / page break
                            // badges on the on-screen preview only.
                            // The exported PDF skips this overlay
                            // because PDFExporter.export passes
                            // showBreakIndicators=false to its
                            // own Canvas-based PDFPageView.
                            .overlay(alignment: .topLeading) {
                                BreakIndicatorOverlay(
                                    mode: .document(
                                        systems: batch.systems,
                                        documentYOffset:
                                        batch.startY
                                            - page.margins(
                                                forPageIndex: idx
                                            ).top,
                                        xOffset: page.margins(
                                            forPageIndex: idx
                                        ).leading
                                    ),
                                    metrics: doc.metrics
                                )
                            }
                            .border(Color.gray.opacity(0.4))
                            .shadow(radius: 3)
                            Text("\(idx + 1) / \(pages.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24))
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator: NSObject {
            var binding: Binding<CGFloat>?
            var lastDocId: ObjectIdentifier?
            var lastPageCount: Int = -1
            var isLiveMagnifying = false

            @objc func willStartLiveMagnify(_ notification: Notification) {
                isLiveMagnifying = true
            }

            @objc func magnificationDidEnd(_ notification: Notification) {
                isLiveMagnifying = false
                guard let scrollView = notification.object as? NSScrollView
                else { return }
                binding?.wrappedValue = scrollView.magnification
            }
        }
    }
#endif
