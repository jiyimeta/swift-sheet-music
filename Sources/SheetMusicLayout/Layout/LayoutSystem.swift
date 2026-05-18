import CoreGraphics
import SheetMusicCore

/// One horizontal line of music. Contains one or more staves stacked
/// vertically and one or more parts.
@available(macOS 15.0, *)
public struct LayoutSystem: Sendable, Equatable {
    public let origin: CGPoint // in document coordinates
    public let size: CGSize
    public let measures: [LayoutMeasure]
    /// Per-staff baselines (top-left in system coordinates).
    public let staffOrigins: [CGPoint]
    /// `StaffAddress` for each entry in `staffOrigins`, in the same
    /// display order. Enables `StaffAddress → flat-index` conversion
    /// without re-visiting the originating `Score`.
    public let staffAddresses: [StaffAddress]
    /// Part labels at the left edge of this system (empty on continuation
    /// systems per MuseScore convention).
    public let partLabels: [LayoutPartLabel]
    /// Brackets / braces drawn at the left edge of this system, one
    /// per `BracketItem` on each staff. Empty when no `Staff.brackets`
    /// were populated upstream.
    public let brackets: [LayoutBracket]
    /// Cross-measure spanner segments (slurs, voltas, hairpins, etc.)
    /// resolved after measure placement. Origins are in system coords.
    public let spanners: [LayoutElement]
    /// Chord/rest anchors of every measure flattened into one
    /// X-sorted index. Built deterministically from `measures` —
    /// callers MUST NOT supply a divergent value via `init`.
    /// Drives `ScoreHitTester.itemIDs(in:)` (marquee) and is the
    /// substrate for future O(log N) nearest-X lookups.
    public let eventColumns: [EventColumn]
    /// Largest `eventColumns[i].bbox.width / 2`, or 0 when empty.
    /// Used as the binary-search tolerance so a rect that intersects
    /// an event's bbox but lies outside its `centerX` still hits.
    public let maxBBoxHalfWidth: CGFloat
    /// Spatium (one staff space, equal to one quarter of the total
    /// staff height) used to compute event bboxes.
    /// Equals `StaffMetrics(staffSize:).sp` for the current staff size.
    public let sp: CGFloat

    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        staffAddresses: [StaffAddress] = [],
        partLabels: [LayoutPartLabel],
        brackets: [LayoutBracket] = [],
        spanners: [LayoutElement],
        sp: CGFloat,
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.staffAddresses = staffAddresses
        self.partLabels = partLabels
        self.brackets = brackets
        self.spanners = spanners
        self.sp = sp
        let columns = Self.buildEventColumns(measures: measures, sp: sp)
        eventColumns = columns
        maxBBoxHalfWidth = columns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
    }

    /// Flat index (= index into `staffOrigins`) for the given address.
    /// Returns `nil` when the address is not present in this system.
    public func flatIndex(for address: StaffAddress) -> Int? {
        staffAddresses.firstIndex(of: address)
    }

    /// Subtype + system-local origin X of the rightmost barline in the
    /// last measure. Returned to renderers that need to know where the
    /// system's terminal barline lives — e.g. to clip staff lines so
    /// they end flush with it instead of extending through the
    /// trailing-barline gutter (≈ 0.5 sp) baked into each measure's
    /// width. `subtype == nil` means a default thin barline; an empty
    /// `measures` array (defensive — never expected in practice)
    /// returns `nil`.
    public var trailingBarLine: (subtype: String?, x: CGFloat)? {
        guard let last = measures.last else { return nil }
        var rightmostX: CGFloat = -.infinity
        var rightmostSubtype: String?
        for el in last.elements {
            if case let .barLine(s, p) = el, p.x > rightmostX {
                rightmostX = p.x
                rightmostSubtype = s
            }
        }
        guard rightmostX.isFinite else { return nil }
        return (rightmostSubtype, last.origin.x + rightmostX)
    }

    private static func buildEventColumns(
        measures: [LayoutMeasure],
        sp: CGFloat,
    ) -> [EventColumn] {
        var result: [EventColumn] = []
        for measure in measures {
            let mx = measure.origin.x
            let my = measure.origin.y
            for el in measure.elements {
                switch el {
                case let .chord(notes, _, _, _, _, _, _, voiceIndex):
                    guard !notes.isEmpty else { continue }
                    let xs = notes.map { mx + $0.origin.x }
                    let ys = notes.map { my + $0.origin.y }
                    guard let minX = xs.min(),
                          let maxX = xs.max(),
                          let minY = ys.min(),
                          let maxY = ys.max(),
                          let topNote = notes.min(by: {
                              $0.origin.y < $1.origin.y
                          })
                    else { continue }
                    // Matches `ScoreHitTester.hitNote`'s hit radius.
                    let pad: CGFloat = sp * 1.2
                    let bbox = CGRect(
                        x: minX - pad,
                        y: minY - pad,
                        width: (maxX - minX) + pad * 2,
                        height: (maxY - minY) + pad * 2,
                    )
                    result.append(EventColumn(
                        id: .note(topNote.noteID),
                        voiceIndex: voiceIndex,
                        centerX: (minX + maxX) / 2,
                        centerY: (minY + maxY) / 2,
                        bbox: bbox,
                    ))
                case let .rest(_, origin, voiceIndex, restID, _):
                    let cx = mx + origin.x
                    let cy = my + origin.y
                    // Matches `ScoreHitTester.hitRest`'s half-extents.
                    let halfW: CGFloat = sp * 1.8
                    let halfH: CGFloat = sp * 2.5
                    let bbox = CGRect(
                        x: cx - halfW, y: cy - halfH,
                        width: halfW * 2, height: halfH * 2,
                    )
                    result.append(EventColumn(
                        id: .rest(restID),
                        voiceIndex: voiceIndex,
                        centerX: cx,
                        centerY: cy,
                        bbox: bbox,
                    ))
                default:
                    continue
                }
            }
        }
        result.sort { $0.centerX < $1.centerX }
        return result
    }
}

@available(macOS 15.0, *)
public struct LayoutPartLabel: Sendable, Equatable {
    public let text: String
    public let origin: CGPoint

    public init(text: String, origin: CGPoint) {
        self.text = text
        self.origin = origin
    }
}

@available(macOS 15.0, *)
public struct LayoutBracket: Sendable, Equatable {
    public let type: BracketType
    /// Top edge of the topmost spanned staff (system coords).
    public let topY: CGFloat
    /// Bottom edge of the bottommost spanned staff (system coords).
    public let bottomY: CGFloat
    /// Horizontal nesting column. 0 sits closest to the staff; higher
    /// values stack further left.
    public let column: Int
    /// Number of staves spanned (after end-of-score clamping). Used by
    /// the brace renderer to select the SMuFL variant glyph and the
    /// per-span horizontal magnification — see MuseScore's
    /// `engraving/dom/bracket.cpp::Bracket::computeMagx`.
    public let staffCount: Int

    public init(
        type: BracketType,
        topY: CGFloat,
        bottomY: CGFloat,
        column: Int,
        staffCount: Int = 1,
    ) {
        self.type = type
        self.topY = topY
        self.bottomY = bottomY
        self.column = column
        self.staffCount = max(staffCount, 1)
    }
}
