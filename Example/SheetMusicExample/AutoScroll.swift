import CoreGraphics
import SheetMusicCore
import SheetMusicUI
import SwiftUI

extension ScoreCursor {
    /// Measure index this cursor is parked on, regardless of `.item`
    /// vs `.beat` flavour. Used by auto-scroll to ask "did the
    /// cursor move into a different measure?".
    var measureIndex: Int {
        switch self {
        case let .item(id): return id.measureIndex
        case let .beat(mi, _): return mi
        }
    }
}

@available(macOS 15.0, iOS 16.0, *)
extension LayoutDocument {
    /// Document-space top-left of the first occurrence of the
    /// measure with `measureIndex`. `nil` if the index isn't found
    /// in any system (e.g. measure was filtered out).
    func measureOrigin(measureIndex: Int) -> CGPoint? {
        for system in systems {
            if let m = system.measures.first(
                where: { $0.measureIndex == measureIndex },
            ) {
                return CGPoint(
                    x: system.origin.x + m.origin.x,
                    y: system.origin.y + m.origin.y,
                )
            }
        }
        return nil
    }

    /// Index of the system that contains the given measure. `nil`
    /// when no system holds that measure.
    func systemIndex(forMeasureIndex mi: Int) -> Int? {
        for (i, sys) in systems.enumerated()
            where sys.measures.contains(where: { $0.measureIndex == mi })
        {
            return i
        }
        return nil
    }
}

/// Identifier for vertical-mode auto-scroll targets. One anchor per
/// system, placed at the system's top Y in document space.
struct VerticalSystemAnchorID: Hashable {
    let systemIndex: Int
}

/// Identifier for horizontal-mode auto-scroll targets. One anchor
/// per measure, placed at the measure's leading X in document space.
struct HorizontalMeasureAnchorID: Hashable {
    let measureIndex: Int
}

/// Per-system frame in the vertical scroll view's named coordinate
/// space (`"vScroll"`). Updated continuously as the user scrolls,
/// so the auto-scroller can ask "is this system on screen *right
/// now*?" without doing scroll-offset arithmetic.
///
/// Reading anchor frames in the ScrollView's space directly is more
/// robust than tracking a scalar scroll offset via PreferenceKey:
/// the latter can lag programmatic `scrollTo` animations on iOS
/// 17+ (UIScrollView-backed) and lead to "is the cursor visible?"
/// checks that always answer the same wrong way until the next
/// frame.
struct VerticalSystemFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect],
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-measure frame in the horizontal scroll view's named coord
/// space (`"hScroll"`). Same purpose as `VerticalSystemFramesKey`
/// but keyed by measure index for the horizontal layout.
struct HorizontalMeasureFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(
        value: inout [Int: CGRect],
        nextValue: () -> [Int: CGRect],
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Per-system invisible anchors stacked in a real `VStack` with
/// spacers sized to the document Y of each anchor. Two jobs:
///
///   * `ScrollViewReader.scrollTo(VerticalSystemAnchorID(systemIndex:),
///     anchor: .top | .bottom)` — snap the system's top staff to
///     the viewport top, or its bottom staff to the viewport
///     bottom.
///   * `VerticalSystemFramesKey` preference — report each anchor's
///     live frame in the scroll view's named coord space
///     (`"vScroll"`), so the host can decide "is this system on
///     screen?" without doing scroll-offset math.
///
/// Each anchor view spans the system's *staff range* — top staff's
/// top through bottom staff's bottom — not the full system rect.
/// That makes `scrollTo(_, anchor: .top)` align the top staff's
/// top with the viewport top, and `anchor: .bottom` align the
/// bottom staff's bottom with the viewport bottom; the cursor
/// (which `cursorFrame` defines exactly as the staff range) never
/// gets clipped by system whitespace. Visibility — the same frame
/// — is also "is the cursor visible," matching the user-facing
/// definition.
///
/// **Why a VStack of spacers and not `.position` / `.offset` /
/// custom `Layout`.** All three break `ScrollViewReader`:
/// `.position` and a custom `Layout` make the modified view's
/// layout frame fill the parent (so every anchor reports the whole
/// document and `scrollTo(_, anchor: .top)` always resolves to
/// document y = 0); `.offset` shifts pixels but leaves the layout
/// frame at the parent origin (so `scrollTo` always targets 0, 0).
/// A real VStack with spacers is the only path that gives every
/// anchor an honest frame the standard layout system reports.
@available(macOS 15.0, iOS 16.0, *)
struct VerticalSystemAnchors: View {
    let document: LayoutDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0 ..< document.systems.count, id: \.self) { i in
                let sys = document.systems[i]
                let topY = staffTopDocY(of: sys)
                let bottomY = staffBottomDocY(of: sys)
                let height = max(0, bottomY - topY)
                let prevBottom: CGFloat = i == 0
                    ? 0
                    : staffBottomDocY(of: document.systems[i - 1])
                let gap = max(0, topY - prevBottom)
                if gap > 0 {
                    Color.clear.frame(width: 1, height: gap)
                }
                Color.clear
                    .frame(width: 1, height: height)
                    .id(VerticalSystemAnchorID(systemIndex: i))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: VerticalSystemFramesKey.self,
                                value: [
                                    i: g.frame(in: .named("vScroll")),
                                ],
                            )
                        },
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading,
        )
        .allowsHitTesting(false)
    }

    private func staffTopDocY(of sys: LayoutSystem) -> CGFloat {
        sys.origin.y + (sys.staffOrigins.first?.y ?? 0)
    }

    private func staffBottomDocY(of sys: LayoutSystem) -> CGFloat {
        sys.origin.y
            + (sys.staffOrigins.last?.y ?? 0)
            + document.metrics.staffHeight
    }
}

/// Per-measure invisible anchors stacked in a real `HStack`. The
/// horizontal counterpart of `VerticalSystemAnchors`. Each anchor
/// is sized to the measure's full width so its preference-reported
/// frame in `.named("hScroll")` *is* the measure's live rect.
@available(macOS 15.0, iOS 16.0, *)
struct HorizontalMeasureAnchors: View {
    let document: LayoutDocument

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0 ..< measures.count, id: \.self) { i in
                let m = measures[i]
                let prevRight: CGFloat = i == 0
                    ? 0
                    : measures[i - 1].docX + measures[i - 1].width
                let gap = max(0, m.docX - prevRight)
                if gap > 0 {
                    Color.clear.frame(width: gap, height: 1)
                }
                Color.clear
                    .frame(width: m.width, height: 1)
                    .id(HorizontalMeasureAnchorID(
                        measureIndex: m.measureIndex,
                    ))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: HorizontalMeasureFramesKey.self,
                                value: [
                                    m.measureIndex:
                                        g.frame(in: .named("hScroll")),
                                ],
                            )
                        },
                    )
            }
            Spacer(minLength: 0)
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading,
        )
        .allowsHitTesting(false)
    }

    private var measures: [(measureIndex: Int, docX: CGFloat, width: CGFloat)] {
        var seen: Set<Int> = []
        var result: [(measureIndex: Int, docX: CGFloat, width: CGFloat)] = []
        for sys in document.systems {
            for m in sys.measures
                where seen.insert(m.measureIndex).inserted
            {
                result.append((
                    measureIndex: m.measureIndex,
                    docX: sys.origin.x + m.origin.x,
                    width: m.width,
                ))
            }
        }
        return result.sorted { $0.docX < $1.docX }
    }
}

// MARK: - Auto-scroll geometry helpers

/// Visibility test for an anchor frame in a scroll view's named
/// coord space. Treats the anchor as visible only when fully inside
/// the viewport — any partial overhang triggers a scroll. The
/// exception: when the anchor is taller / wider than the viewport
/// (nothing we can do), fall back to "any overlap" so the auto-
/// scroll heuristic doesn't oscillate between top and bottom
/// alignment on every cursor step.
func isAnchorFullyVisible(
    anchorMin: CGFloat,
    anchorMax: CGFloat,
    anchorSize: CGFloat,
    viewportSize: CGFloat,
) -> Bool {
    if anchorSize > viewportSize {
        return anchorMax > 0 && anchorMin < viewportSize
    }
    return anchorMin >= 0 && anchorMax <= viewportSize
}

/// Build a `UnitPoint` that, when passed to
/// `ScrollViewReader.scrollTo(_, anchor:)`, leaves `pad` points
/// between the anchor edge and the matching viewport edge.
///
/// `scrollTo` aligns the target's anchor point with the viewport's
/// anchor point — same `UnitPoint` for both. With `y_unit = y`:
///
///     scrollOffset = target.minY + y * (target.height - viewport.height)
///
/// To place `target.minY` at `pad` (top-aligned with `pad` inset),
/// solve for `y` → `y = pad / (viewport - target)`. Bottom-aligned
/// with `pad` inset is the mirror: `y = 1 - pad / (viewport - target)`.
///
/// When `target >= viewport` the anchor is bigger than the viewport
/// — no room for padding, fall back to plain `.top` / `.bottom`.
/// Same when `denom <= pad`: keeping `pad` on the chosen side would
/// push the opposite edge off.
func paddedScrollAnchor(
    aboveViewport: Bool,
    anchorSize: CGFloat,
    viewportSize: CGFloat,
    pad: CGFloat,
    horizontal: Bool,
) -> UnitPoint {
    let denom = viewportSize - anchorSize
    let frac: CGFloat
    if denom <= pad {
        frac = aboveViewport ? 0 : 1
    } else if aboveViewport {
        frac = pad / denom
    } else {
        frac = 1 - pad / denom
    }
    return horizontal
        ? UnitPoint(x: frac, y: 0.5)
        : UnitPoint(x: 0.5, y: frac)
}
