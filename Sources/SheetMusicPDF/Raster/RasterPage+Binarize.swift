import Foundation

/// The raster front-end: page bitmap → the `paths` stream of
/// `WalkedContent`. Caseless enum, mirroring `PDFImporter`'s shape.
enum RasterPage {}

extension RasterPage {
    /// Otsu's global threshold — the grey level maximizing between-class
    /// variance.
    ///
    /// Global rather than local (Sauvola and friends) on purpose: the
    /// input class is engraved print, and the illumination a scanner
    /// introduces is removed by `flattenBackground` before this runs. A
    /// local method here would be a second unmeasured variable solving a
    /// problem the first one already solved.
    static func otsuThreshold(_ bitmap: GrayBitmap) -> UInt8 {
        var histogram = [Double](repeating: 0, count: 256)
        for pixel in bitmap.pixels {
            histogram[Int(pixel)] += 1
        }
        let total = Double(bitmap.pixels.count)
        guard total > 0 else { return 128 }
        var sumAll = 0.0
        for (value, count) in histogram.enumerated() {
            sumAll += Double(value) * count
        }

        var weightBelow = 0.0
        var sumBelow = 0.0
        var bestVariance = 0.0
        var bestLow = 0
        var bestHigh = 0
        for t in 0 ..< 256 {
            weightBelow += histogram[t]
            sumBelow += Double(t) * histogram[t]
            guard weightBelow > 0 else { continue }
            let weightAbove = total - weightBelow
            guard weightAbove > 0 else { break }
            let meanBelow = sumBelow / weightBelow
            let meanAbove = (sumAll - sumBelow) / weightAbove
            let spread = meanBelow - meanAbove
            let variance = weightBelow * weightAbove * spread * spread
            if variance > bestVariance {
                bestVariance = variance
                bestLow = t
                bestHigh = t
            } else if variance == bestVariance, bestVariance > 0 {
                bestHigh = t
            }
        }
        // The MIDPOINT of the maximizing plateau, not its first member.
        // A cleanly printed page is close to two-valued, and then EVERY
        // threshold between the two values scores identically — taking
        // the first would put the threshold hard against the ink, where
        // one grey level of noise is enough to lose a staff line. The
        // plateau midpoint sits between the modes, which is what the
        // criterion means to say.
        //
        // A page with a single grey level has no between-class variance
        // at any split, so the plateau is never entered and this returns
        // 0: nothing is ink, which is the right reading of blank paper.
        return UInt8((bestLow + bestHigh) / 2)
    }

    /// Divide out a coarse background estimate — the per-block paper
    /// level — so that one global threshold stays usable under the
    /// scanner profile's illumination gradient.
    ///
    /// The block maximum is the estimate because paper is the brightest
    /// thing in any block that contains engraving; a mean would be pulled
    /// down by the ink it is supposed to ignore.
    static func flattenBackground(_ bitmap: GrayBitmap, blockPx: Int = 64) -> GrayBitmap {
        let blocksX = max(1, (bitmap.width + blockPx - 1) / blockPx)
        let blocksY = max(1, (bitmap.height + blockPx - 1) / blockPx)
        var background = [Double](repeating: 255, count: blocksX * blocksY)
        for by in 0 ..< blocksY {
            for bx in 0 ..< blocksX {
                var brightest: UInt8 = 0
                for y in by * blockPx ..< min(bitmap.height, (by + 1) * blockPx) {
                    for x in bx * blockPx ..< min(bitmap.width, (bx + 1) * blockPx) {
                        brightest = max(brightest, bitmap[x, y])
                    }
                }
                background[by * blocksX + bx] = Double(max(brightest, 1))
            }
        }
        var out = bitmap
        for y in 0 ..< bitmap.height {
            let by = min(blocksY - 1, y / blockPx)
            for x in 0 ..< bitmap.width {
                let bx = min(blocksX - 1, x / blockPx)
                let level = background[by * blocksX + bx]
                let scaled = Double(bitmap[x, y]) * 255.0 / level
                out[x, y] = UInt8(min(255.0, max(0.0, scaled)))
            }
        }
        return out
    }

    /// Flatten, then threshold. `true` is ink.
    static func binarize(_ bitmap: GrayBitmap) -> InkMask {
        let flat = flattenBackground(bitmap)
        let threshold = otsuThreshold(flat)
        var bits = [Bool](repeating: false, count: flat.pixels.count)
        for i in 0 ..< flat.pixels.count {
            bits[i] = flat.pixels[i] <= threshold
        }
        return InkMask(bits: bits, width: flat.width, height: flat.height)
    }
}
