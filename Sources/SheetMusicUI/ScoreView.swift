import SheetMusicCore
import SwiftUI

/// Read-only SwiftUI view that renders a `Score`.
///
/// Bundles the Bravura SMuFL font for glyph drawing.
///
/// Performance: each system (line of music) is a separate `Canvas`
/// hosted in a `LazyVStack`, so only visible systems are rendered
/// during scrolling. `Canvas(opaque: true, rendersAsynchronously:
/// true)` moves rasterisation off the main thread.
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
            GeometryReader { proxy in
                let w = max(proxy.size.width, options.staffSize * 4)
                let doc = LayoutEngine.layout(
                    score: score, options: options,
                    availableWidth: w)
                systemStack(doc: doc)
            }
            .frame(minHeight: estimatedHeight)
        } else {
            let naturalWidth = LayoutEngine.naturalContentWidth(
                score: score, options: options)
            let doc = LayoutEngine.layout(
                score: score, options: options,
                availableWidth: naturalWidth)
            systemStack(doc: doc)
        }
    }

    /// A lazy vertical stack of per-system canvases. Only visible
    /// systems are drawn — the biggest perf win for long scores.
    @ViewBuilder
    private func systemStack(doc: LayoutDocument) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<doc.systems.count, id: \.self) { idx in
                SystemCanvas(
                    system: doc.systems[idx],
                    metrics: doc.metrics)
            }
        }
        .frame(width: doc.size.width)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    /// Rough height estimate so GeometryReader doesn't collapse to
    /// zero inside a vertical ScrollView.
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
