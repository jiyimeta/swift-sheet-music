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
        // Compute a single layout at the score's natural width.
        // The document's own size (derived from actual system extents
        // inside LayoutEngine.layout) is the frame — so the white
        // canvas and the scrollable area match exactly.
        let naturalWidth = LayoutEngine.naturalContentWidth(
            score: score, options: options)
        let doc = LayoutEngine.layout(
            score: score, options: options,
            availableWidth: naturalWidth)
        return ScoreCanvas(document: doc)
    }
}
#endif
