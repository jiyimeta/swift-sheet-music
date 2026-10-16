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

    /// Places `items`. `title` is the leading box's bottom edge and its `bottomGap` in spatium (`nil` gap = 7 sp), or
    /// `nil` when the document has no title block.
    package static func place(
        title: (bottom: CGFloat, bottomGap: CGFloat?)?,
        items: [Item],
        sp: CGFloat,
    ) -> Result {
        // Phase A stub: sized zeros, so a caller indexing the result does not trap.
        var systemCount = 0
        var frameCount = 0
        for item in items {
            switch item.kind {
            case .system: systemCount += 1
            case .frame: frameCount += 1
            }
        }
        return Result(
            systemShift: Array(repeating: 0, count: systemCount),
            frameOriginY: Array(repeating: 0, count: frameCount),
            contentBottom: 0,
        )
    }
}
