import CoreGraphics
import SheetMusicCore

/// One horizontal line of music. Contains one or more staves stacked
/// vertically and one or more parts.
@available(macOS 15.0, iOS 16.0, *)
public struct LayoutSystem: Sendable, Equatable {
    public let origin: CGPoint       // in document coordinates
    public let size: CGSize
    public let measures: [LayoutMeasure]
    /// Per-staff baselines (top-left in system coordinates).
    public let staffOrigins: [CGPoint]
    /// Part labels at the left edge of this system (empty on continuation
    /// systems per MuseScore convention).
    public let partLabels: [LayoutPartLabel]
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

    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        partLabels: [LayoutPartLabel],
        spanners: [LayoutElement]
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.partLabels = partLabels
        self.spanners = spanners
        let columns = Self.buildEventColumns(measures: measures)
        self.eventColumns = columns
        self.maxBBoxHalfWidth = columns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
    }

    private static func buildEventColumns(
        measures: [LayoutMeasure]
    ) -> [EventColumn] {
        var result: [EventColumn] = []
        for measure in measures {
            let mx = measure.origin.x
            let my = measure.origin.y
            for el in measure.elements {
                switch el {
                case .chord(
                    let notes, _, _, _, _, _, _,
                    let voiceIndex
                ):
                    guard !notes.isEmpty else { continue }
                    let xs = notes.map { mx + $0.origin.x }
                    let ys = notes.map { my + $0.origin.y }
                    guard let minX = xs.min(),
                          let maxX = xs.max(),
                          let minY = ys.min(),
                          let maxY = ys.max(),
                          let topNote = notes.min(by: {
                              $0.origin.y < $1.origin.y })
                    else { continue }
                    // Notehead radius approximation. `LayoutSystem`
                    // doesn't carry `sp`, so we use a conservative
                    // absolute pad that matches the tester's
                    // `sp * 1.2` hit radius for typical staff sizes.
                    let pad: CGFloat = 4.5
                    let bbox = CGRect(
                        x: minX - pad,
                        y: minY - pad,
                        width: (maxX - minX) + pad * 2,
                        height: (maxY - minY) + pad * 2)
                    result.append(EventColumn(
                        id: .note(topNote.noteID),
                        voiceIndex: voiceIndex,
                        centerX: (minX + maxX) / 2,
                        centerY: (minY + maxY) / 2,
                        bbox: bbox))
                case .rest(_, let origin, let voiceIndex, let restID, _):
                    let cx = mx + origin.x
                    let cy = my + origin.y
                    let halfW: CGFloat = 6.5      // ≈ 1.8 sp at sp=3.5
                    let halfH: CGFloat = 9.0      // ≈ 2.5 sp at sp=3.5
                    let bbox = CGRect(
                        x: cx - halfW, y: cy - halfH,
                        width: halfW * 2, height: halfH * 2)
                    result.append(EventColumn(
                        id: .rest(restID),
                        voiceIndex: voiceIndex,
                        centerX: cx,
                        centerY: cy,
                        bbox: bbox))
                default:
                    continue
                }
            }
        }
        result.sort { $0.centerX < $1.centerX }
        return result
    }
}

@available(macOS 15.0, iOS 16.0, *)
public struct LayoutPartLabel: Sendable, Equatable {
    public let text: String
    public let origin: CGPoint

    public init(text: String, origin: CGPoint) {
        self.text = text
        self.origin = origin
    }
}
