#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// TIME-SIGNATURE READING for the score-state walk
// (PDFImporter+ScoreState). Split out of that file to keep each under the
// SwiftLint length cap, mirroring PDFImporter+KeyReader.

extension PDFImporter {
    /// The LEADING time signature of a measure, or nil when it declares
    /// none. Scans left-to-right and stops at the first CONTENT glyph — a
    /// signature past it is the courtesy announcing the NEXT measure's
    /// change, not this measure's own (see `isLeadingRegionTerminator`).
    static func readTime(from glyphs: [ClassifiedGlyph]) -> TimeSignature? {
        for glyph in glyphs {
            if isLeadingRegionTerminator(glyph.semantic) { return nil }
            switch glyph.semantic {
            // The page drew a symbol, so the meter it stands for is the one to report — and the symbol
            // itself is kept, so re-engraving the imported score draws the C the page had rather than a 4
            // over a 4.
            case .timeSignatureCommon:
                return TimeSignature(numerator: 4, denominator: 4, symbol: .common)
            case .timeSignatureCutTime:
                return TimeSignature(numerator: 2, denominator: 2, symbol: .cutCommon)
            case .timeSignatureDigit:
                return parseStackedDigits(from: glyphs)
            default: continue
            }
        }
        return nil
    }

    /// Group digit glyphs by x-cluster (within 3pt). Within a cluster
    /// the higher-y glyph is the numerator and the lower-y glyph is
    /// the denominator. Side-by-side digits (two distinct x-clusters)
    /// are read as `num / denom`.
    ///
    /// Takes the LEFTMOST cluster pair, so a measure carrying both its own
    /// leading signature and a trailing courtesy still reads the leading one.
    private static func parseStackedDigits(
        from glyphs: [ClassifiedGlyph],
    ) -> TimeSignature? {
        let digits = collectDigits(from: glyphs)
        guard !digits.isEmpty else { return nil }
        let clusters = clusterDigitsByX(digits)
        let firstCluster = clusters[0]
        if firstCluster.count >= 2 {
            let sortedByY = firstCluster.sorted { $0.y > $1.y }
            return TimeSignature(
                numerator: sortedByY[0].n,
                denominator: sortedByY[1].n,
            )
        }
        if clusters.count >= 2 {
            return TimeSignature(
                numerator: firstCluster[0].n,
                denominator: clusters[1][0].n,
            )
        }
        return TimeSignature(numerator: firstCluster[0].n, denominator: 4)
    }

    private struct DigitGlyph {
        var x: CGFloat
        var y: CGFloat
        var n: Int
    }

    private static func collectDigits(
        from glyphs: [ClassifiedGlyph],
    ) -> [DigitGlyph] {
        glyphs.compactMap { g in
            if case let .timeSignatureDigit(n) = g.semantic {
                return DigitGlyph(x: g.geometry.origin.x, y: g.geometry.origin.y, n: n)
            }
            return nil
        }
    }

    private static func clusterDigitsByX(
        _ digits: [DigitGlyph],
    ) -> [[DigitGlyph]] {
        let sorted = digits.sorted { $0.x < $1.x }
        var clusters: [[DigitGlyph]] = []
        for digit in sorted {
            if let lastDigit = clusters.last?.last,
               abs(digit.x - lastDigit.x) < 3
            {
                clusters[clusters.count - 1].append(digit)
            } else {
                clusters.append([digit])
            }
        }
        return clusters
    }
}
