#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Which authored `<LayoutBreak>` a badge stands for.
public enum BreakIndicatorKind: Sendable, Equatable {
    case line
    case page
}

/// One break-indicator badge: what it says and where its centre sits.
///
/// Position is in **document** coordinates — the same space `LayoutSystem.origin` and
/// `ScoreHitTester` work in — so a host places it by the same transform it uses for everything
/// else. The badge itself is drawn at a fixed size by whoever renders it and deliberately does NOT
/// scale with the staff: it is an authoring hint about the file, not notation, and a hint that
/// shrinks with the music becomes unreadable exactly when the score is zoomed out to look at its
/// breaks.
public struct BreakIndicatorPlacement: Sendable, Equatable {
    public let kind: BreakIndicatorKind
    public let x: CGFloat
    public let y: CGFloat

    public init(kind: BreakIndicatorKind, x: CGFloat, y: CGFloat) {
        self.kind = kind
        self.x = x
        self.y = y
    }
}

/// Where MuseScore-style break-indicator badges go, given a laid-out document and the two options
/// that govern them.
///
/// Lives here rather than in the SwiftUI overlay that used to own it because it is pure geometry
/// over `LayoutMeasure.lineBreak` / `.pageBreak`, and a second renderer needs the identical answer.
/// A badge that appears on Apple and not on Android — or on a measure whose break the current
/// `LayoutBreakPolicy` is ignoring — is a lie about the file, so the rule gets one spelling.
public enum BreakIndicators {
    /// Badge centre's distance above the system's top edge. Sits the badge slightly clear of the
    /// top staff so it floats without overlapping staff lines.
    public static func badgeOffsetY(metrics: StaffMetrics) -> CGFloat {
        metrics.sp * 0.5
    }

    /// The badge `measure` earns under `policy` and `visibility`, or `nil`.
    ///
    /// `policy` gates before `visibility` does, and the order matters: under `.ignoreSystemBreaks`
    /// the engine does not act on `<LayoutBreak>line` at all, so drawing its badge would point at a
    /// break that is not happening. `.ignoreAll` shows nothing for the same reason.
    public static func kind(
        for measure: LayoutMeasure,
        policy: LayoutBreakPolicy,
        visibility: BreakIndicatorVisibility,
    ) -> BreakIndicatorKind? {
        let byPolicy: BreakIndicatorKind?
        switch policy {
        case .honor:
            if measure.pageBreak {
                byPolicy = .page
            } else if measure.lineBreak {
                byPolicy = .line
            } else {
                byPolicy = nil
            }
        case .ignoreSystemBreaks:
            byPolicy = measure.pageBreak ? .page : nil
        case .ignoreAll:
            byPolicy = nil
        }
        guard let kind = byPolicy else { return nil }
        switch visibility {
        case .all: return kind
        case .pageOnly: return kind == .page ? kind : nil
        case .none: return nil
        }
    }

    /// Every badge for `systems`, in document coordinates.
    ///
    /// A badge sits at the measure's trailing edge — where the break happens — and above the
    /// system it belongs to.
    public static func placements(
        systems: [LayoutSystem],
        metrics: StaffMetrics,
        policy: LayoutBreakPolicy,
        visibility: BreakIndicatorVisibility,
    ) -> [BreakIndicatorPlacement] {
        guard visibility != .none, policy != .ignoreAll else { return [] }
        let dy = badgeOffsetY(metrics: metrics)
        return systems.flatMap { system in
            system.measures.compactMap { measure in
                guard let kind = kind(for: measure, policy: policy, visibility: visibility) else {
                    return nil
                }
                return BreakIndicatorPlacement(
                    kind: kind,
                    x: system.origin.x + measure.origin.x + measure.width,
                    y: system.origin.y + dy,
                )
            }
        }
    }
}
