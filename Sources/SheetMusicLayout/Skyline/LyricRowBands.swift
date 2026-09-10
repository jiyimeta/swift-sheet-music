#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Staff-wide row bands preserve verse order even when the syllables have disjoint X ranges.
/// Fixed rows contribute constraints but are never moved. A movable row only moves outward;
/// an authored fixed outer row can therefore remain inside a pushed movable inner row.
struct LyricRowBands {
    private var bands: [LyricRow: CGRect] = [:]

    mutating func add(_ box: CGRect, to row: LyricRow) {
        bands[row] = bands[row]?.union(box) ?? box
    }

    func outwardShift(for row: LyricRow, box: CGRect, minimumGap: CGFloat) -> CGFloat {
        var shift: CGFloat = 0
        for (other, band) in bands where other.side == row.side {
            if row.side == .above, other.verse > row.verse {
                shift = min(shift, band.minY - minimumGap - box.maxY)
            } else if row.side == .below, other.verse < row.verse {
                shift = max(shift, band.maxY + minimumGap - box.minY)
            }
        }
        return shift
    }
}
