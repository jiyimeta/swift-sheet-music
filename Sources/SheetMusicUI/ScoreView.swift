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
        GeometryReader { proxy in
            let width = max(proxy.size.width, 100)
            let doc = LayoutEngine.layout(
                score: score,
                options: options,
                availableWidth: width
            )
            ScoreCanvas(document: doc)
        }
    }
}
#endif
