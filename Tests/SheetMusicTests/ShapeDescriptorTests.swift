#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct ShapeDescriptorTests {
        /// N horizontal bars stacked vertically within a FIXED overall
        /// bounding box (width 60, height 60) — a stand-in for the N flags of
        /// a rest or a beamed flag glyph. The envelope is held constant
        /// across `n` because real rest/flag families (rest8th…rest64th,
        /// flag8thUp…flag64thUp) keep roughly the same overall glyph size —
        /// only the internal flag count grows. A stand-in whose bbox instead
        /// grows with `n` (an earlier version of this helper did) defeats the
        /// whole premise of `nearerForSameFamilyThanAcrossFamilies`: bitmap
        /// L1 distance is then dominated by the differing envelope rather
        /// than the differing stroke count, and same-family pairs measure
        /// FARTHER apart than cross-family pairs. See task-10-report.md for
        /// the measured before/after distances.
        private func bars(_ n: Int) -> CGPath {
            let path = CGMutablePath()
            let totalHeight: CGFloat = 60
            let unit = totalHeight / CGFloat(2 * n - 1)
            for i in 0 ..< n {
                let y = CGFloat(i) * 2 * unit
                path.addRect(CGRect(x: 0, y: y, width: 60, height: unit))
            }
            return path
        }

        @Test func countsVerticalProjectionPeaks() {
            #expect(makeDescriptor(path: bars(2)).flagPeaks == 2)
            #expect(makeDescriptor(path: bars(3)).flagPeaks == 3)
        }

        @Test func distanceIsZeroForIdenticalShapes() {
            let a = makeDescriptor(path: bars(3))
            let b = makeDescriptor(path: bars(3))
            #expect(a.distance(to: b) == 0)
        }

        @Test func nearerForSameFamilyThanAcrossFamilies() {
            let twoBars = makeDescriptor(path: bars(2))
            let threeBars = makeDescriptor(path: bars(3))
            let disc = CGMutablePath()
            disc.addEllipse(in: CGRect(x: 0, y: 0, width: 40, height: 30))
            let notehead = makeDescriptor(path: disc)
            #expect(twoBars.distance(to: threeBars) < twoBars.distance(to: notehead))
        }

        @Test func scaleInvariant() {
            let small = CGMutablePath()
            small.addEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 8))
            let large = CGMutablePath()
            large.addEllipse(in: CGRect(x: 100, y: 50, width: 100, height: 80))
            #expect(
                makeDescriptor(path: small)
                    .distance(to: makeDescriptor(path: large)) < 0.05,
            )
        }
    }
#endif
