import QuartzCore
import SheetMusicCore
import SheetMusicLayout

/// What of a system is worth building layers for.
///
/// A horizontally engraved score is a single system, so mounting whole systems — what `ScoreView`'s `visibleRect`
/// does for a vertical document — mounts all of it: 60,667 layers and about 104 MB for a 508-measure, six-staff score,
/// 97 % of them in the measure containers. Within a system the unit is therefore the measure, plus the system-level
/// spanners and hidden elements drawn beside the measures.
///
/// **A measure is mounted by its frame**, `[origin.x, origin.x + width]`, not by the ink it draws. Ink can reach past
/// the frame — an accidental before the barline, a lyric past it — but on that 508-measure score by at most 0.8 sp, so
/// the margin a host already keeps around its viewport covers it. Measuring a measure's ink would mean building it.
enum SystemMount {
    /// Whether `measure`'s frame meets `range` (system-local X). Everything meets `nil`.
    static func meets(_ measure: LayoutMeasure, _ range: ClosedRange<CGFloat>?) -> Bool {
        guard let range else { return true }
        return measure.origin.x <= range.upperBound && measure.origin.x + measure.width >= range.lowerBound
    }

    /// Whether a system-level spanner's span meets `range` (system-local X). A spanner whose span is not known from
    /// its two ends (`horizontalExtent(of:)`) always does, as does everything with `nil`.
    static func meets(spanner: LayoutElement, _ range: ClosedRange<CGFloat>?) -> Bool {
        guard let range, let extent = horizontalExtent(of: spanner) else { return true }
        return extent.overlaps(range)
    }

    /// The X span between a line-like element's two ends, or `nil` for any other element. Spanners, ties, glissandi
    /// and lyric lines are drawn between their two ends; a slur's control points stay inside them.
    static func horizontalExtent(of element: LayoutElement) -> ClosedRange<CGFloat>? {
        let ends: (CGPoint, CGPoint)
        switch element {
        case let .spannerSegment(_, from, to, _, _, _, _): ends = (from, to)
        case let .tieArc(from, to, _, _): ends = (from, to)
        case let .glissandoLine(from, to, _, _, _): ends = (from, to)
        case let .lyricsMelisma(from, to, _): ends = (from, to)
        case let .lyricHyphen(from, to, _): ends = (from, to)
        default: return nil
        }
        return min(ends.0.x, ends.1.x) ... max(ends.0.x, ends.1.x)
    }
}

/// The layers one system-level piece draws straight onto the root — one spanner, or the shared group of hidden
/// elements — and the selectable ones among them, so a host can mount and unmount the piece as a unit.
struct MountedLayers {
    let layers: [CALayer]
    let items: [ScoreItemID: [CAShapeLayer]]
}

/// Which hidden elements the shared invisible group holds: the measures, by `LayoutMeasure.measureIndex`, whose
/// hidden elements it draws, and the indices into `LayoutSystem.invisibleSpanners` it draws.
///
/// The group is one 50 %-opacity layer rather than one per measure so that overlapping hidden elements composite as
/// one grey (see `MeasureLayerDiffPlanner.systemFrameIsUnchanged`), which means it cannot be mounted a measure at a
/// time: a host rebuilds it whenever this changes.
struct InvisibleMembership: Equatable {
    var measures: [Int] = []
    var spanners: [Int] = []

    var isEmpty: Bool {
        measures.isEmpty && spanners.isEmpty
    }

    /// Holds nothing — what a host starts from before its first build.
    init() {}

    init(system: LayoutSystem, visibleXRange: ClosedRange<CGFloat>?) {
        measures = system.measures
            .filter { !$0.invisibleElements.isEmpty && SystemMount.meets($0, visibleXRange) }
            .map(\.measureIndex)
        spanners = system.invisibleSpanners.indices.filter {
            SystemMount.meets(spanner: system.invisibleSpanners[$0], visibleXRange)
        }
    }
}

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    /// One system-level spanner's layers, drawn into a detached parent the size of the system so the host decides
    /// where in the root they go.
    static func buildSpanner(
        _ spanner: LayoutElement, of system: LayoutSystem, metrics: StaffMetrics,
    ) -> MountedLayers {
        let height = system.size.height + 1
        let scratch = CALayer()
        scratch.frame = CGRect(origin: .zero, size: CGSize(width: system.size.width, height: height))
        var ctx = BuildContext()
        ctx.showsInvisibleElements = system.showsInvisibleElements
        drawElement(spanner, base: .zero, metrics: metrics, height: height, context: &ctx, into: scratch)
        let layers = scratch.sublayers ?? []
        scratch.sublayers = nil
        return MountedLayers(layers: layers, items: ctx.items)
    }

    /// The hidden elements `membership` names, in a half-opacity group the size of the system, or `nil` when it names
    /// none. MuseScore invisibleColor() = #808080; 50% black on white is the exact equivalent.
    static func buildInvisibleGroup(
        _ system: LayoutSystem, membership: InvisibleMembership, metrics: StaffMetrics,
    ) -> MountedLayers? {
        guard !membership.isEmpty else { return nil }
        let height = system.size.height + 1
        let group = CALayer()
        group.frame = CGRect(origin: .zero, size: CGSize(width: system.size.width, height: height))
        group.opacity = 0.5
        group.masksToBounds = false
        // Routed-to-invisible chord/note glyphs already sit under the group's 50% opacity; flip the flag so per-note
        // dispatch grays those noteheads rather than skipping them.
        var ctx = BuildContext()
        ctx.showsInvisibleElements = true
        let measures = Set(membership.measures)
        for measure in system.measures where measures.contains(measure.measureIndex) {
            let base = CGPoint(x: measure.origin.x, y: measure.origin.y)
            for element in measure.invisibleElements {
                drawElement(element, base: base, metrics: metrics, height: height, context: &ctx, into: group)
            }
        }
        for index in membership.spanners {
            drawElement(
                system.invisibleSpanners[index], base: .zero, metrics: metrics, height: height,
                context: &ctx, into: group,
            )
        }
        return MountedLayers(layers: [group], items: ctx.items)
    }
}
