#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Which side of the staff an autoplaced item is pushed toward.
public enum AutoplaceSide: Sendable, Equatable {
    case above
    case below
}

/// MuseScore's autoplace style constants and collision-exemption
/// rules, restricted to the element set `SheetMusicLayout` emits.
///
/// Distances come from `src/engraving/style/styledef.cpp`; the
/// exemption rules mirror `Autoplace::itemsShouldIgnoreEachOther`
/// (`src/engraving/rendering/score/autoplace.cpp`).
public enum AutoplaceRules {
    /// Minimum clearance between an item and the skyline it is pushed
    /// away from, in points.
    public static func minDistance(
        for kind: ShapeItemKind, sp: CGFloat,
    ) -> CGFloat {
        switch kind {
        case .lyrics, .lyricsMelisma, .lyricHyphen:
            // Sid::lyricsMinDistance = 0.25 sp.
            sp * 0.25
        default:
            // Sid::minVerticalDistance = 0.5 sp is the shared default,
            // and dynamics / tempo / measureNumber / systemText /
            // staffText / rehearsalMark / minHarmonyDistance all
            // happen to equal it.
            sp * 0.5
        }
    }

    /// `Sid::skylineMinHorizontalClearance` = 0.25 sp. Articulations
    /// and fermatas opt out (MuseScore passes 0 for them so they can
    /// nest tightly against a notehead column).
    public static func horizontalClearance(
        for kind: ShapeItemKind, sp: CGFloat,
    ) -> CGFloat {
        switch kind {
        case .articulation, .fermata: 0
        default: sp * 0.25
        }
    }

    /// True when the pair must not influence each other's placement.
    public static func shouldIgnoreEachOther(
        _ a: ShapeItem, _ b: ShapeItem,
    ) -> Bool {
        // An item never pushes itself.
        if a.id == b.id { return true }
        // Dynamics and hairpins snap into one chain instead.
        let pair = Set([a.kind, b.kind])
        if pair == Set([ShapeItemKind.dynamics, .hairpin]) { return true }
        guard a.kind == b.kind else { return false }
        // Same kind: non-text kinds ignore each other; text kinds
        // collide — except dynamics, which align as a chain.
        if a.kind == .dynamics { return true }
        return !a.kind.isText
    }

    /// True for the kinds the skyline pass is allowed to move.
    public static func isAutoplaced(_ kind: ShapeItemKind) -> Bool {
        if defaultSide(for: kind) != nil { return true }
        return sideFollowsPosition.contains(kind)
    }

    /// Spanner kinds whose side is read off the element rather than
    /// fixed by the kind.
    ///
    /// `Autoplace::autoplaceSpannerSegment` takes it from the spanner
    /// itself — `bool above = item->spanner()->placeAbove()`
    /// (`autoplace.cpp:223`) — never from a per-kind table. An authored
    /// `<placement>` is already baked into the segment's Y by the time
    /// the pass sees it, so the Y IS `placeAbove()`. Fixing a side per
    /// kind would push a hairpin flipped above the staff back down
    /// through it.
    private static let sideFollowsPosition: Set<ShapeItemKind> = [
        .hairpin, .pedal, .ottava, .textLine,
    ]

    /// Side of the staff `kind` is pushed toward, or `nil` when the
    /// element's own Y decides — see `sideFollowsPosition`.
    public static func defaultSide(
        for kind: ShapeItemKind,
    ) -> AutoplaceSide? {
        switch kind {
        case .dynamics, .lyrics, .lyricsMelisma, .lyricHyphen:
            .below
        case .tempo, .measureNumber, .harmony, .staffText, .systemText,
             .rehearsalMark, .marker, .jump, .volta:
            .above
        default:
            nil
        }
    }
}
