#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// The geometry of the vertical stream between the title and the systems when mid-score boxes are present: where each
/// box goes and how far each system moves down. A pure function of heights and gaps (no fonts).
///
/// The rules come from MuseScore's `SystemLayout::minDistance` (`systemlayout.cpp:2895-2925`). Gaps are in spatium and
/// a missing one is 7 sp; the padding to notation is 2 sp. A box's distance REPLACES the baked inter-system distance
/// on either side of it, so a system after a box is moved by the difference.
package enum FrameStreamPlacer {
    /// One entry of the stream, top to bottom.
    package struct Item: Sendable, Equatable {
        package enum Kind: Sendable, Equatable {
            /// A system's natural top and bottom, in points.
            case system(top: CGFloat, bottom: CGFloat)
            /// A box: gaps in spatium (`nil` = the 7 sp default), height in points.
            case frame(topGap: CGFloat?, bottomGap: CGFloat?, height: CGFloat)
        }

        package var kind: Kind

        package init(kind: Kind) {
            self.kind = kind
        }
    }

    package struct Result: Sendable, Equatable {
        /// Per system, in stream order: the CUMULATIVE distance the system moves down (everything after a box moves
        /// by the sum of the distances replaced so far).
        package var systemShift: [CGFloat]
        /// Per box, in stream order: its top edge.
        package var frameOriginY: [CGFloat]
        /// The bottom of the stream: the last system's shifted bottom, or the last box's bottom.
        package var contentBottom: CGFloat
    }

    private static let defaultGap: CGFloat = 7
    private static let paddingToNotation: CGFloat = 2

    /// What the stream's last entry was.
    private enum Previous {
        case start
        case title(gap: CGFloat?)
        case system
        case frame(gap: CGFloat?)
    }

    /// Places `items`. `title` is the leading box's bottom edge and its `bottomGap` in spatium (`nil` gap = 7 sp), or
    /// `nil` when the document has no title block. A title followed by a system keeps its baked distance (shift 0).
    /// `top` is where the stream starts when there is no title (the document's top margin); a box that comes first
    /// sits on it.
    package static func place(
        title: (bottom: CGFloat, bottomGap: CGFloat?)?,
        items: [Item],
        sp: CGFloat,
        top: CGFloat = 0,
    ) -> Result {
        var shifts: [CGFloat] = []
        var origins: [CGFloat] = []
        var previous: Previous = title.map { Previous.title(gap: $0.bottomGap) } ?? Previous.start
        var lastBottom: CGFloat = title?.bottom ?? top
        var shift: CGFloat = 0
        for item in items {
            switch item.kind {
            case let .system(top, bottom):
                if case let .frame(gap) = previous {
                    shift = lastBottom + max(gap ?? defaultGap, paddingToNotation) * sp - top
                }
                shifts.append(shift)
                lastBottom = bottom + shift
                previous = .system
            case let .frame(topGap, bottomGap, height):
                let originY = lastBottom + distance(from: previous, topGap: topGap) * sp
                origins.append(originY)
                lastBottom = originY + height
                previous = .frame(gap: bottomGap)
            }
        }
        return Result(systemShift: shifts, frameOriginY: origins, contentBottom: lastBottom)
    }

    /// The distance in spatium from the previous entry's bottom to a box's top (MS `minDistance`).
    private static func distance(from previous: Previous, topGap: CGFloat?) -> CGFloat {
        switch previous {
        case .start:
            return 0
        case .system:
            return max(topGap ?? defaultGap, paddingToNotation)
        case let .title(gap), let .frame(gap):
            let above = gap ?? defaultGap
            let below = topGap ?? defaultGap
            return above >= 0 && below >= 0 ? max(above, below) : above + below
        }
    }
}
