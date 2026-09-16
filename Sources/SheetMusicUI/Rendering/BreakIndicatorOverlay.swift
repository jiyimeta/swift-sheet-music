import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// Renders MuseScore-style line / page break indicators at the
/// top-right corner of measures that carry an explicit
/// `<LayoutBreak>`. A pure SwiftUI overlay — never participates in
/// layout (drawn outside the score `Canvas` / `CALayer` tree) so
/// PDF export simply omits the overlay and gets an indicator-free
/// document.
///
/// Two flavours:
/// * `.system(system:)` — drops indicators for one `LayoutSystem`
///   in that system's local frame (origin = (0,0) at the system's
///   top-left). Use as a SwiftUI `.overlay` on a per-system view
///   like `SystemLayerView`.
/// * `.document(systems:)` — drops indicators for many systems in
///   document-Y coords. Used by the on-screen paginated PDF
///   preview where systems share a single page coordinate space.
@available(macOS 15.0, *)
public struct BreakIndicatorOverlay: View {
    public enum Mode {
        /// Single system, indicator placed in the system's local
        /// frame.
        case system(system: LayoutSystem)
        /// Multiple systems sharing a page-local coordinate space.
        /// `documentYOffset` subtracts the page's start-Y; `xOffset`
        /// adds the page's left-margin (mirrors `PDFPageView`'s
        /// `translateBy`).
        case document(
            systems: [LayoutSystem],
            documentYOffset: CGFloat,
            xOffset: CGFloat,
        )
    }

    public let mode: Mode
    public let metrics: StaffMetrics
    public let policy: LayoutBreakPolicy
    public let visibility: BreakIndicatorVisibility

    public init(
        mode: Mode,
        metrics: StaffMetrics,
        policy: LayoutBreakPolicy = .honor,
        visibility: BreakIndicatorVisibility = .all,
    ) {
        self.mode = mode
        self.metrics = metrics
        self.policy = policy
        self.visibility = visibility
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Transparent background so the overlay doesn't shade
            // the score; SwiftUI hit-testing falls through to the
            // underlying Canvas / layer view (we also turn it off
            // explicitly below).
            Color.clear
            ForEach(Array(indicators.enumerated()), id: \.offset) { _, ind in
                BreakIndicatorBadge(kind: ind.kind)
                    .position(x: ind.x, y: ind.y)
            }
        }
        .allowsHitTesting(false)
    }

    private var indicators: [Indicator] {
        switch mode {
        case let .system(s):
            return s.measures.compactMap { m in
                guard let kind = breakKind(for: m) else { return nil }
                // Local-to-system coords: measure origin is
                // already system-local.
                let x = m.origin.x + m.width
                let y = badgeOffsetY(metrics: metrics)
                return Indicator(kind: kind, x: x, y: y)
            }
        case let .document(systems, dY, xOffset):
            var out: [Indicator] = []
            for s in systems {
                for m in s.measures {
                    guard let kind = breakKind(for: m) else { continue }
                    let x = s.origin.x + m.origin.x
                        + m.width + xOffset
                    let y = s.origin.y - dY
                        + badgeOffsetY(metrics: metrics)
                    out.append(Indicator(kind: kind, x: x, y: y))
                }
            }
            return out
        }
    }

    /// Delegates to `SheetMusicLayout.BreakIndicators`.
    ///
    /// The rule moved down when a second renderer needed the identical answer: a badge that appears
    /// on one platform and not another — or on a measure whose break the current `LayoutBreakPolicy`
    /// is ignoring — is a lie about the file, and two spellings of "which measure earns a badge" is
    /// how that happens. This view keeps its own `BreakKind` because it is the type its badge sub-view
    /// switches on; the mapping is one line either way.
    private func breakKind(for m: LayoutMeasure) -> BreakKind? {
        switch BreakIndicators.kind(for: m, policy: policy, visibility: visibility) {
        case .line: .line
        case .page: .page
        case nil: nil
        }
    }

    /// See `BreakIndicators.badgeOffsetY(metrics:)`.
    private func badgeOffsetY(metrics: StaffMetrics) -> CGFloat {
        BreakIndicators.badgeOffsetY(metrics: metrics)
    }

    private struct Indicator {
        let kind: BreakKind
        let x: CGFloat
        let y: CGFloat
    }

    public enum BreakKind: Sendable {
        case line, page
    }
}

/// One small badge — an outlined SF Symbol approximating MuseScore's break-indicator iconography.
///
/// Ink only, with no filled plate behind it and no filled symbol. The badge is authoring chrome sitting on top of
/// the music, and a solid colored block at the end of every broken measure pulled the eye away from the notation
/// it annotates; an outline in the same hue still reads as "a break is here" without competing with the staff.
@available(macOS 15.0, *)
private struct BreakIndicatorBadge: View {
    let kind: BreakIndicatorOverlay.BreakKind

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(badgeColor)
            .frame(width: 16, height: 12)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch kind {
        // `arrow.turn.down.left` is the closest stock approximation
        // of MuseScore's "↵" line-break icon.
        case .line: return "arrow.turn.down.left"
        // Page break: an outlined page conveys "force a page break here".
        case .page: return "doc"
        }
    }

    private var badgeColor: Color {
        switch kind {
        // Slate blue for line break — distinct enough from staff
        // ink so the indicator reads as UI chrome, not engraving.
        case .line: return Color(red: 0.40, green: 0.55, blue: 0.85)
        // Plum for page break — separates it visually from line
        // break at a glance.
        case .page: return Color(red: 0.65, green: 0.40, blue: 0.78)
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .line: "Line break"
        case .page: "Page break"
        }
    }
}
