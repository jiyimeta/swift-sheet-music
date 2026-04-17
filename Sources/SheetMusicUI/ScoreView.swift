import SheetMusicCore
import SwiftUI

/// Read-only SwiftUI view that renders a `Score`.
///
/// macOS 15+ only. Bundles the Bravura SMuFL font for glyph drawing.
@available(macOS 15.0, iOS 16.0, *)
public struct ScoreView: View {
    private let score: Score
    private let options: ScoreViewOptions

    public init(score: Score, options: ScoreViewOptions = .init()) {
        _ = BravuraFont.register
        self.score = score
        self.options = options
    }

    public var body: some View {
        if options.wrapToViewWidth {
            // Wrap mode: use GeometryReader to get the container width
            // and break measures into systems that fit. Ideal for
            // portrait iPhone layouts (2–3 measures per line).
            GeometryReader { proxy in
                let w = max(proxy.size.width, options.staffSize * 4)
                let doc = LayoutEngine.layout(
                    score: score, options: options,
                    availableWidth: w)
                ScoreCanvas(document: doc)
            }
            .frame(minHeight: estimatedHeight)
        } else {
            // Natural-width mode: single system, horizontal scroll.
            let naturalWidth = LayoutEngine.naturalContentWidth(
                score: score, options: options)
            let doc = LayoutEngine.layout(
                score: score, options: options,
                availableWidth: naturalWidth)
            ScoreCanvas(document: doc)
        }
    }

    /// Rough height estimate so GeometryReader doesn't collapse to
    /// zero inside a vertical ScrollView. Assumes ~3 measures per
    /// system as a conservative default.
    private var estimatedHeight: CGFloat {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let measureCount = score.staves.first?.measures.count ?? 1
        let systemCount = max(1, (measureCount + 2) / 3)
        let staffCount = max(1, score.staves.count)
        let systemHeight = metrics.sp * 16
            + CGFloat(staffCount) * (metrics.staffHeight + metrics.sp * 8)
        return CGFloat(systemCount) * (systemHeight + options.systemGap)
    }
}
