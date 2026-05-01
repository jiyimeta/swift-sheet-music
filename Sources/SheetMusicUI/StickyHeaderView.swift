import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Sticky header pane for horizontal continuous-view UIs.
///
/// Renders the active clef, key signature, time signature, instrument
/// name and current measure number for the leftmost visible measure
/// at scroll position `documentScrollX`. As the host scrolls the
/// underlying score, the pane re-renders so the reader always sees
/// the current engraving state without having to scroll back to
/// measure 1 — mirroring MuseScore's continuous view.
///
/// Place it as a fixed-position overlay at the viewport's left edge
/// (e.g. inside an overlay `ZStack` aligned `.topLeading`). The pane
/// sizes itself to fit its contents; the host should clip beyond the
/// returned width when overlaying so the underlying score scrolls
/// independently of the sticky region.
@available(macOS 15.0, iOS 16.0, *)
public struct StickyHeaderView: View {
    private let document: LayoutDocument
    private let documentScrollX: CGFloat
    private let measureContexts: [LayoutMeasureContext]

    public init(
        document: LayoutDocument,
        measureContexts: [LayoutMeasureContext],
        documentScrollX: CGFloat
    ) {
        self.document = document
        self.measureContexts = measureContexts
        self.documentScrollX = documentScrollX
    }

    /// Convenience: compute measure contexts on the fly. Suitable
    /// for one-off / static use; performance-sensitive callers
    /// (e.g. live pinch / scroll) should cache the contexts in their
    /// own state and use the explicit-array initialiser so they
    /// don't pay an O(measures × staves) recompute on every body
    /// re-evaluation.
    public init(
        document: LayoutDocument,
        score: Score,
        documentScrollX: CGFloat
    ) {
        self.init(
            document: document,
            measureContexts: LayoutEngine.measureContexts(for: score),
            documentScrollX: documentScrollX
        )
    }

    public var body: some View {
        let measureIdx = document
            .measureIndex(atDocumentX: documentScrollX) ?? 0
        let safeIdx = min(
            max(0, measureIdx), measureContexts.count - 1
        )
        if safeIdx >= 0,
           safeIdx < measureContexts.count,
           let template = document.systems.first
        {
            let context = measureContexts[safeIdx]
            let synth = LayoutEngine.stickyHeaderSystem(
                for: context,
                templateSystem: template,
                metrics: document.metrics
            )
            ZStack(alignment: .topLeading) {
                Color.white
                SystemLayerView(
                    system: synth, metrics: document.metrics
                )
                // Render the frozen elements at MuseScore's
                // `invisibleColor()` (#808080, 50 % gray on
                // white) — see `continuouspanel.cpp:417`. 50 %
                // black-on-white is the exact equivalent.
                .opacity(0.5)
            }
            // Match the score's system frame, which adds 1 px to the
            // system height inside `SystemLayerView`. Lining up the
            // pane's bottom with the score's white background bottom
            // depends on this — without the +1 the sticky would be
            // a hairline shorter than the music it sits over.
            .frame(
                width: synth.size.width,
                height: synth.size.height + 1,
                alignment: .topLeading
            )
            .environment(\.colorScheme, .light)
        }
    }
}
