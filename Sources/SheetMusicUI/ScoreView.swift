#if os(macOS)
import SheetMusicCore
import SwiftUI

/// Read-only SwiftUI view that renders a `Score`.
///
/// macOS 15+ only. Bundles the Bravura SMuFL font for glyph drawing.
@available(macOS 15.0, *)
public struct ScoreView: View {
    private let score: Score
    private let options: ScoreViewOptions

    public init(score: Score, options: ScoreViewOptions = .init()) {
        _ = BravuraFont.register
        self.score = score
        self.options = options
    }

    public var body: some View {
        // Precompute a "natural" single-system layout. Its size is what
        // ScoreView reports as its ideal size — the parent uses that when
        // it proposes nil (e.g. `ScrollView([.vertical, .horizontal])`
        // proposes nil on both axes). Without an ideal size, GeometryReader
        // collapses to ~10×10 and the score renders as an unreadable sliver.
        let naturalWidth = LayoutEngine.naturalContentWidth(
            score: score, options: options)
        let naturalDoc = LayoutEngine.layout(
            score: score, options: options,
            availableWidth: naturalWidth)
        return GeometryReader { proxy in
            let doc = resolvedLayout(
                proposedWidth: proxy.size.width,
                naturalWidth: naturalWidth,
                naturalDoc: naturalDoc)
            ScoreCanvas(document: doc)
        }
        // Size the view to EXACTLY the rendered document so the
        // ScrollView's scrollable area matches the white canvas — no
        // excess right or bottom margin.
        .frame(
            width: naturalDoc.size.width,
            height: naturalDoc.size.height)
    }

    /// Pick the layout to render based on the width the parent offers.
    /// Falls back to the pre-computed natural layout when the parent
    /// didn't propose a usable width (GeometryReader returns ~10 when
    /// hosted in a bidirectional ScrollView).
    private func resolvedLayout(
        proposedWidth: CGFloat,
        naturalWidth: CGFloat,
        naturalDoc: LayoutDocument
    ) -> LayoutDocument {
        let minUsableWidth: CGFloat = options.staffSize * 4
        guard proposedWidth.isFinite, proposedWidth >= minUsableWidth else {
            return naturalDoc
        }
        if !options.wrapToViewWidth {
            return naturalDoc
        }
        if abs(proposedWidth - naturalWidth) < 1 {
            return naturalDoc
        }
        return LayoutEngine.layout(
            score: score, options: options,
            availableWidth: proposedWidth)
    }
}
#endif
