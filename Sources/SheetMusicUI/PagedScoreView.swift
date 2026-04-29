import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Paginated score view that displays one page of systems at a time.
///
/// Systems are wrapped to the available width (like vertical-scroll
/// mode) then grouped into pages by available height. The caller
/// controls navigation via the `pageIndex` binding; `totalPages`
/// is written back when layout completes.
@available(macOS 15.0, iOS 16.0, *)
public struct PagedScoreView: View {
    private let score: Score
    private let options: ScoreViewOptions
    @Binding private var pageIndex: Int
    @Binding private var totalPages: Int

    public init(
        score: Score,
        options: ScoreViewOptions = .init(),
        pageIndex: Binding<Int>,
        totalPages: Binding<Int>
    ) {
        _ = BravuraFont.register
        self.score = score
        self.options = options
        self._pageIndex = pageIndex
        self._totalPages = totalPages
    }

    public var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, options.staffSize * 4)
            let pageOpts = ScoreViewOptions(
                staffSize: options.staffSize,
                systemGap: options.systemGap,
                wrapToViewWidth: true)
            let doc = LayoutEngine.layout(
                score: score, options: pageOpts,
                availableWidth: w)
            let pages = Self.paginate(
                systems: doc.systems,
                pageHeight: proxy.size.height)
            let count = max(1, pages.count)
            let safe = min(max(pageIndex, 0), count - 1)
            let pageSystems = safe >= 0 && safe < pages.count
                ? pages[safe] : []

            ZStack(alignment: .topLeading) {
                Canvas(opaque: true, rendersAsynchronously: true) { ctx, size in
                    ctx.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.white))
                    var localY: CGFloat = 0
                    for system in pageSystems {
                        var sub = ctx
                        sub.translateBy(
                            x: -system.origin.x,
                            y: localY - system.origin.y)
                        ScoreCanvasDrawing.drawSystem(
                            system, metrics: doc.metrics, into: &sub)
                        localY += system.size.height
                    }
                }
                // Indicator overlay laid out in this page's
                // coord space. The Canvas above translates each
                // system by `localY - system.origin.y` so that
                // system N's local-(x, y) lines up with
                // page-(x, y - system.origin.y + sumOfPriorHeights).
                // We mirror that mapping by passing a synthetic
                // `documentYOffset` per system; cleanest way is
                // to overlay one per-system indicator strip.
                let pageOrigins = Self.systemPageOrigins(
                    pageSystems: pageSystems)
                ForEach(
                    Array(pageSystems.enumerated()),
                    id: \.offset
                ) { idx, sys in
                    BreakIndicatorOverlay(
                        mode: .system(system: sys),
                        metrics: doc.metrics)
                        .frame(width: sys.size.width,
                               height: sys.size.height,
                               alignment: .topLeading)
                        .offset(
                            x: sys.origin.x,
                            y: pageOrigins[idx])
                }
            }
            .frame(width: doc.size.width, height: proxy.size.height)
            .environment(\.colorScheme, .light)
            .preference(key: PageCountKey.self, value: count)
        }
        .onPreferenceChange(PageCountKey.self) { count in
            totalPages = count
            if pageIndex >= count {
                pageIndex = max(0, count - 1)
            }
        }
    }

    static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat
    ) -> [[LayoutSystem]] {
        guard !systems.isEmpty, pageHeight > 0 else { return [] }
        var pages: [[LayoutSystem]] = []
        var current: [LayoutSystem] = []
        var usedHeight: CGFloat = 0

        for system in systems {
            let h = system.size.height
            if !current.isEmpty && usedHeight + h > pageHeight {
                pages.append(current)
                current = []
                usedHeight = 0
            }
            current.append(system)
            usedHeight += h
            // `<LayoutBreak>page` on the last measure of this
            // system forces the page to close immediately, even
            // if more systems would still fit vertically.
            if system.measures.last?.pageBreak == true {
                pages.append(current)
                current = []
                usedHeight = 0
            }
        }
        if !current.isEmpty {
            pages.append(current)
        }
        return pages
    }

    /// Y offset (in page-local coords) for each system on the
    /// current page. Mirrors the `localY` accumulator inside the
    /// Canvas drawing pass — required so the indicator overlay
    /// lands at the same on-screen position as the system itself.
    static func systemPageOrigins(
        pageSystems: [LayoutSystem]
    ) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var localY: CGFloat = 0
        for system in pageSystems {
            offsets.append(localY)
            localY += system.size.height
        }
        return offsets
    }
}

private struct PageCountKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue = 1
    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = nextValue()
    }
}
