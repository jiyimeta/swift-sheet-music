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

    private func breakKind(for m: LayoutMeasure) -> BreakKind? {
        let policyKind: BreakKind?
        switch policy {
        case .honor:
            if m.pageBreak {
                policyKind = .page
            } else if m.lineBreak {
                policyKind = .line
            } else {
                policyKind = nil
            }
        case .ignoreSystemBreaks:
            // Page indicators only — line breaks are ignored at
            // layout time, so showing their badges would mislead.
            policyKind = m.pageBreak ? .page : nil
        case .ignoreAll:
            policyKind = nil
        }
        guard let kind = policyKind else { return nil }
        switch visibility {
        case .all: return kind
        case .pageOnly: return kind == .page ? kind : nil
        case .none: return nil
        }
    }

    /// Badge centre's distance from the system's top edge. We sit
    /// the badge slightly above the top staff so it floats clearly
    /// without overlapping staff lines.
    private func badgeOffsetY(metrics: StaffMetrics) -> CGFloat {
        metrics.sp * 0.5
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

/// One small badge — a rounded rectangle with an SF Symbol
/// approximating MuseScore's break-indicator iconography.
@available(macOS 15.0, *)
private struct BreakIndicatorBadge: View {
    let kind: BreakIndicatorOverlay.BreakKind

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 16, height: 12)
            .background(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(badgeColor),
            )
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch kind {
        // `arrow.turn.down.left` is the closest stock approximation
        // of MuseScore's "↵" line-break icon.
        case .line: return "arrow.turn.down.left"
        // Page break: a "doc" with a downward arrow conveys
        // "force a page break here".
        case .page: return "doc.fill"
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
