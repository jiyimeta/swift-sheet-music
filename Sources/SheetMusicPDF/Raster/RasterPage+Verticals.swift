#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

extension RasterPage {
    /// Shortest column run emitted as a `.vertical`, in staff spaces.
    ///
    /// This sits exactly at the length of the shortest REAL vertical — a
    /// stem — and that is not a coincidence, it is the whole mechanism.
    /// Below it is glyph ink: the strokes inside clefs, accidentals and
    /// time signatures, which the vector path never emits as paths at all
    /// because MuseScore draws them as glyphs. Above it, stems (~3.5 sp)
    /// and barlines (4.0 sp) both pass, deliberately — they overlap in
    /// length, so nothing here could separate them, and
    /// `barlineCandidates` already separates them downstream using
    /// notehead abutment, which this stage does not have.
    ///
    /// The value was 2.0 for most of this stage's life, chosen by
    /// reasoning ("below this is notehead-interior noise") rather than
    /// measured — the only major constant in the raster front-end that
    /// was. Profiling predicted verticals against the labels over 493
    /// pages showed 85% of all false positives sitting under 3.5 sp,
    /// 7,845 of them in the 2.0 bucket alone at 3% purity. Swept through
    /// the hybrid on 177 renders:
    ///
    ///     floor    pitch p50   pitch mean   dur p50   dur mean
    ///     2.0      52          46.6         38        42.0
    ///     2.5      66          54.0         51        48.5
    ///     3.0      66          54.1         52        48.6
    ///     3.5      98          65.4         55        50.3
    ///     4.0      93          64.5         38        40.7
    ///
    /// The peak is bracketed on both sides: 4.0 starts cutting the stems
    /// themselves and duration collapses with them. Exact measure counts
    /// stay at 130/177 across the whole sweep, so this is pure gain and
    /// not a structure trade.
    static let verticalMinLengthInSpaces = 3.5

    /// Shortest column run kept when it TOUCHES A DETECTED BEAM, in staff
    /// spaces.
    ///
    /// A beamed note's stem is shortened — the beam comes to meet it — so
    /// the plain floor above, which sits at a free stem's length, cuts
    /// exactly the stems that carry beam membership. Measured, that is
    /// what caps duration: on `tex_0028` the note values collapse
    /// `16:14->8 8:9->3 q:13->32`, i.e. beamed notes arriving as quarters
    /// because their stems never reached the rhythm pass. The profile
    /// says ~8,400 genuine verticals live below 3.5 sp.
    ///
    /// Length alone cannot separate those from the clef and accidental
    /// strokes the floor exists to reject — but a beam can. This stage
    /// detects beams before verticals, and a clef stroke does not touch
    /// one while a shortened stem always does.
    ///
    /// Swept on 177 renders (the plain floor stays at 3.5 throughout):
    ///
    ///     beamed floor   pitch p50   pitch mean   dur p50   measures exact
    ///     (no rule)      98          65.4         55        130
    ///     1.5            83          61.4         58        127
    ///     2.5            97          65.2         58        130
    ///     3.0            97          65.2         58        130
    ///
    /// 2.5 and 3.0 are identical, so the whole gain comes from the
    /// [3.0, 3.5) band — a beamed stem is only slightly shorter than a
    /// free one. 3.0 is chosen for the same result on less admitted ink.
    /// At 1.5 the rule starts pulling in notehead-interior ink, which
    /// sits directly under a beam in a beamed chord, and costs 15 points
    /// of pitch to buy the same 3 points of duration.
    static let verticalBeamedMinLengthInSpaces = 3.0

    // NO UPPER LENGTH LIMIT, and the reason is worth keeping.
    //
    // A profile of predicted verticals said heights of 12 staff spaces
    // and above were 17 genuine against 476 spurious, which looked like
    // an easy win. Capping at 11 sp cost pitch median 52 -> 23 and exact
    // measure counts 130 -> 76.
    //
    // The profile's labels were wrong, not the detector. The vector path
    // emits a barline as ONE SEGMENT PER STAFF — nine 4.0 sp segments
    // stacked at the same x — while the raster merges the whole column
    // into one tall run, so a genuine system-spanning barline matches no
    // single truth segment by centre distance and is counted spurious.
    // It is the same representation-granularity trap as the staff-line
    // fragments, in a third disguise: whenever truth splits something
    // the raster merges, a one-to-one metric scores a correct answer as
    // a false positive.

    /// Widest run still emitted as a `.vertical`, in staff spaces.
    ///
    /// Without this, BEAMS come out as verticals. A stack of three or
    /// four fused beams is 2.00 or 2.75 staff spaces thick — above
    /// `verticalMinLengthInSpaces` — and its columns all overlap in y, so
    /// the whole beam group would group into one blob and be emitted as a
    /// vertical the width of the beam. A real vertical is a stem
    /// (~0.15 sp wide) or a barline or bracket (up to ~0.6 sp); the
    /// narrowest beam measured on this dataset is 1.30 sp long, so 1.0 sp
    /// separates the two classes with margin on both sides.
    static let verticalMaxWidthInSpaces = 1.0

    /// Inked stretches of one column, top to bottom.
    static func columnRuns(_ mask: InkMask, x: Int) -> [(y0: Int, y1: Int)] {
        var out: [(y0: Int, y1: Int)] = []
        var start: Int?
        for y in 0 ..< mask.height {
            if mask[x, y] {
                if start == nil { start = y }
            } else if let from = start {
                out.append((from, y - 1))
                start = nil
            }
        }
        if let from = start { out.append((from, mask.height - 1)) }
        return out
    }

    /// A vertical run and the columns it spans.
    private struct VerticalBlob {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
    }

    /// Column runs long enough to be a stem or a barline, grouped across
    /// adjacent columns by y-overlap into one segment each.
    ///
    /// Columns are walked left to right and runs top to bottom —
    /// raster-scan order — so the emitted order is a function of the mask
    /// alone.
    static func verticalSegments(
        _ mask: InkMask, spacingPx: Double, transform: PageTransform, pageIndex: Int,
        beams: [PathSegment] = [],
    ) -> [PathSegment] {
        let minLengthPx = Int((verticalBeamedMinLengthInSpaces * spacingPx).rounded())
        var open: [VerticalBlob] = []
        var closed: [VerticalBlob] = []
        for x in 0 ..< mask.width {
            let runs = columnRuns(mask, x: x).filter { $0.y1 - $0.y0 + 1 >= minLengthPx }
            var next: [VerticalBlob] = []
            var consumed = [Bool](repeating: false, count: runs.count)
            for var blob in open {
                var extended = false
                for (i, run) in runs.enumerated()
                    where !consumed[i] && run.y0 <= blob.y1 && run.y1 >= blob.y0
                {
                    blob.y0 = min(blob.y0, run.y0)
                    blob.y1 = max(blob.y1, run.y1)
                    blob.x1 = x
                    consumed[i] = true
                    extended = true
                }
                if extended { next.append(blob) } else { closed.append(blob) }
            }
            for (i, run) in runs.enumerated() where !consumed[i] {
                next.append(VerticalBlob(x0: x, x1: x, y0: run.y0, y1: run.y1))
            }
            open = next
        }
        closed.append(contentsOf: open)

        let maxWidthPx = max(1, Int((verticalMaxWidthInSpaces * spacingPx).rounded()))
        let freeLengthPx = Int((verticalMinLengthInSpaces * spacingPx).rounded())
        let spacingPt = spacingPx * 72.0 / transform.dpi
        // Length is judged in PIXELS, on the blob, and never by
        // converting a finished segment back: the round trip through
        // points reintroduces rounding right at the threshold, and a stem
        // exactly at the floor came back as 41.999… pixels and vanished.
        return closed
            .filter { $0.x1 - $0.x0 + 1 <= maxWidthPx }
            .sorted { ($0.x0, $0.y0) < ($1.x0, $1.y0) }
            .compactMap { blob -> PathSegment? in
                let seg = segment(from: blob, transform: transform, pageIndex: pageIndex)
                if blob.y1 - blob.y0 + 1 >= freeLengthPx { return seg }
                return touchesBeam(seg, beams: beams, spacingPt: spacingPt) ? seg : nil
            }
    }

    /// Whether a vertical's x sits within a beam's x-range and its y-span
    /// reaches that beam's edges there — i.e. it is a stem the beam
    /// arrives at, rather than a stroke that merely happens to be short.
    private static func touchesBeam(
        _ seg: PathSegment, beams: [PathSegment], spacingPt: Double,
    ) -> Bool {
        let x = seg.rect.midX
        let slack = CGFloat(0.5 * spacingPt)
        for beam in beams {
            guard let quad = beam.quad, quad.xRange.contains(x) else { continue }
            let top = quad.topY(at: x)
            let bottom = quad.botY(at: x)
            if seg.rect.maxY >= bottom - slack, seg.rect.minY <= top + slack {
                return true
            }
        }
        return false
    }

    private static func segment(
        from blob: VerticalBlob, transform: PageTransform, pageIndex: Int,
    ) -> PathSegment {
        let midX = Double(blob.x0 + blob.x1 + 1) / 2
        let top = transform.point(x: midX, y: Double(blob.y0))
        let bottom = transform.point(x: midX, y: Double(blob.y1 + 1))
        let widthPt = Double(blob.x1 - blob.x0 + 1) * (72.0 / transform.dpi)
        return PathSegment(
            kind: .vertical,
            rect: CGRect(
                x: top.x, y: bottom.y, width: 0, height: top.y - bottom.y,
            ),
            lineWidth: CGFloat(widthPt),
            pageIndex: pageIndex,
            quad: nil,
        )
    }
}
