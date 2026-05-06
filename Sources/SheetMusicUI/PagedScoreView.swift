// swiftlint:disable function_body_length file_length
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
        _pageIndex = pageIndex
        _totalPages = totalPages
    }

    public var body: some View {
        GeometryReader { proxy in
            pageContent(in: proxy)
        }
        .onPreferenceChange(PageCountKey.self) { count in
            totalPages = count
            if pageIndex >= count {
                pageIndex = max(0, count - 1)
            }
        }
    }

    @ViewBuilder
    private func pageContent(in proxy: GeometryProxy) -> some View {
        let w = max(proxy.size.width, options.staffSize * 4)
        let pageOpts = ScoreViewOptions(
            staffSize: options.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true,
            breakPolicy: options.breakPolicy
        )
        let doc = LayoutEngine.layout(
            score: score, options: pageOpts,
            availableWidth: w
        )
        let pages = Self.paginate(
            systems: doc.systems,
            pageHeight: proxy.size.height,
            policy: options.breakPolicy
        )
        let count = max(1, pages.count)
        let safe = min(max(pageIndex, 0), count - 1)
        let pageSystems = safe >= 0 && safe < pages.count
            ? pages[safe] : []

        ZStack(alignment: .topLeading) {
            Canvas(opaque: true, rendersAsynchronously: true) { ctx, size in
                ctx.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.white)
                )
                var localY: CGFloat = 0
                for system in pageSystems {
                    var sub = ctx
                    sub.translateBy(
                        x: -system.origin.x,
                        y: localY - system.origin.y
                    )
                    ScoreCanvasDrawing.drawSystem(
                        system, metrics: doc.metrics, into: &sub
                    )
                    localY += system.size.height
                }
            }
            indicatorOverlay(
                pageSystems: pageSystems, metrics: doc.metrics
            )
        }
        .frame(width: doc.size.width, height: proxy.size.height)
        .environment(\.colorScheme, .light)
        .preference(key: PageCountKey.self, value: count)
    }

    /// Indicator overlay laid out in this page's coord space. The
    /// Canvas in `pageContent` translates each system by
    /// `localY - system.origin.y`, so we mirror that mapping here
    /// by overlaying one badge strip per system at its page-local
    /// origin.
    @ViewBuilder
    private func indicatorOverlay(
        pageSystems: [LayoutSystem],
        metrics: StaffMetrics
    ) -> some View {
        if options.showBreakIndicators {
            let pageOrigins = Self.systemPageOrigins(
                pageSystems: pageSystems)
            ForEach(
                Array(pageSystems.enumerated()),
                id: \.offset
            ) { idx, sys in
                BreakIndicatorOverlay(
                    mode: .system(system: sys),
                    metrics: metrics,
                    policy: options.breakPolicy
                )
                .frame(
                    width: sys.size.width,
                    height: sys.size.height,
                    alignment: .topLeading
                )
                .offset(x: sys.origin.x, y: pageOrigins[idx])
            }
        }
    }

    static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy = .honor
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
            // `<LayoutBreak>page` on the last measure of this system
            // closes the page immediately under `.honor` /
            // `.ignoreSystemBreaks`. `.ignoreAll` lets the page keep
            // packing until vertical overflow.
            if policy != .ignoreAll,
               system.measures.last?.pageBreak == true
            {
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
