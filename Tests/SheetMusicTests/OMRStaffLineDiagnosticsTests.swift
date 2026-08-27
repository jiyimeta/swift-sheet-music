#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// Unit tests for the parts of `OMRStaffLineDiagnostics` that make a
    /// CLAIM rather than a count.
    ///
    /// `pitchFlipStaves=0` over 572 staves is the sentence the staff-line
    /// round rests on — it is what says a dy histogram with a visible bias
    /// costs no pitch. A probe that can only ever answer zero would say
    /// exactly the same thing, so the counterfactual needs a case where it
    /// answers something else.
    struct OMRStaffLineDiagnosticsTests {
        static func staff(bottom: CGFloat, spacing: CGFloat) -> SheetMusicPDF.Staff {
            SheetMusicPDF.Staff(
                pageIndex: 0,
                yLines: (0 ..< 5).map { bottom + spacing * CGFloat($0) },
                xRange: 0 ... 500,
                barlineCandidates: [],
            )
        }

        @Test func anIdenticalStaffFlipsNothing() {
            let truth = Self.staff(bottom: 100, spacing: 4.56)
            #expect(OMRStaffLineDiagnostics.pitchFlips(raster: truth, truth: truth).isEmpty)
        }

        /// The bias the corpus actually carries — the matched-line dy mean
        /// is +0.034 staff spaces — must flip nothing. A quantiser reads
        /// `(y − bottom) / (span/8)` through `.rounded()`, so it has a
        /// quarter of a space of slack in each direction and this uses a
        /// fifteenth.
        @Test func aSubToleranceAnchorErrorFlipsNothing() {
            let truth = Self.staff(bottom: 100, spacing: 4.56)
            let raster = Self.staff(bottom: 100 + 0.034 * 4.56, spacing: 4.56)
            #expect(OMRStaffLineDiagnostics.pitchFlips(raster: raster, truth: truth).isEmpty)
        }

        /// Half a step of anchor error is the smallest error that moves a
        /// pitch, and it must move EVERY position — that is what makes it
        /// a whole staff's worth of wrong notes rather than one note's.
        @Test func aHalfStepAnchorErrorFlipsEveryPosition() {
            let truth = Self.staff(bottom: 100, spacing: 4.56)
            let raster = Self.staff(bottom: 100 - 4.56 / 2, spacing: 4.56)
            let flips = OMRStaffLineDiagnostics.pitchFlips(raster: raster, truth: truth)
            #expect(flips.count == OMRStaffLineDiagnostics.pitchProbePositions.count)
        }

        /// A SCALE error costs nothing near the anchor and everything far
        /// from it, which is why the probe sweeps ledger positions instead
        /// of only the staff's own nine.
        @Test func aScaleErrorFlipsOnlyThePositionsFarFromTheAnchor() {
            let truth = Self.staff(bottom: 100, spacing: 4.56)
            let raster = Self.staff(bottom: 100, spacing: 4.56 * 1.1)
            let flips = OMRStaffLineDiagnostics.pitchFlips(raster: raster, truth: truth)
            #expect(!flips.isEmpty)
            #expect(!flips.contains(0))
            #expect(flips.contains(14))
        }

        /// Buckets must tile the axis through zero, or a bias reads as a
        /// symmetric spread: `.rounded()` would give the zero bucket twice
        /// the width of every other one.
        @Test func bucketsKeepTheirSign() {
            #expect(OMRStaffLineDiagnostics.bucket(0.01) == 0)
            #expect(OMRStaffLineDiagnostics.bucket(-0.01) == -1)
            #expect(OMRStaffLineDiagnostics.bucket(0.05) == 1)
            #expect(OMRStaffLineDiagnostics.bucket(-0.05) == -1)
        }
    }
#endif
