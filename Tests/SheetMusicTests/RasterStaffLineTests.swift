#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    struct RasterStaffLineTests {
        static func page(spacingPx: Int = 12) -> GrayBitmap {
            RasterTestBitmaps.staff(
                widthPx: 900, heightPx: 300, dpi: 300, topY: 120, spacingPx: spacingPx,
            )
        }

        static func transform(_ bmp: GrayBitmap) -> PageTransform {
            PageTransform(
                dpi: bmp.dpi, widthPx: bmp.width, heightPx: bmp.height,
                deskewDegrees: 0,
            )
        }

        @Test func staffSpacingIsMeasuredNotAssumed() {
            let mask = RasterPage.binarize(Self.page(spacingPx: 12))
            let spacing = RasterPage.estimateStaffSpacingPx(mask)
            #expect(spacing != nil)
            #expect(abs((spacing ?? 0) - 12) <= 1)
        }

        @Test func aBlankPageHasNoStaffSpacing() {
            let blank = RasterTestBitmaps.blank(widthPx: 200, heightPx: 200, dpi: 300)
            #expect(RasterPage.estimateStaffSpacingPx(RasterPage.binarize(blank)) == nil)
        }

        @Test func fiveLinesBecomeFiveHorizontalSegments() {
            let bmp = Self.page()
            let mask = RasterPage.binarize(bmp)
            let spacing = RasterPage.estimateStaffSpacingPx(mask) ?? 0
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: spacing, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 5)
            #expect(segs.allSatisfy { $0.kind == .horizontal })
            #expect(segs.allSatisfy { $0.pageIndex == 0 })
        }

        /// A line broken by the threshold / erode stages must come out as
        /// ONE segment. `detectStaves` positions lines only from segments
        /// wider than `lineClusterWidthGate` = 50pt, so a line delivered
        /// as fragments is a DROPPED line, not a slightly worse one — the
        /// merge has to happen before emission.
        @Test func aLineBrokenByGapsIsStillOneSegment() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            // Six inked chunks separated by 10px gaps — under the 12px
            // (1.0 staff space at spacing 12) tolerance.
            for chunk in 0 ..< 6 {
                let x0 = 45 + chunk * 135
                RasterTestBitmaps.hLine(&bmp, y: 150, x0: x0, x1: x0 + 125, thickness: 1)
            }
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            let wide = segs.filter { $0.rect.width > 50 }
            #expect(wide.count == 1)
        }

        /// A ROW OF LEDGER LINES must not be bridged into a staff line.
        ///
        /// This is the defect the ink-fraction gate exists for: each mark
        /// is ~1.6 spaces, far too short to be a candidate alone, and the
        /// vector path leaves them as fragments the importer discards —
        /// but a 1.0-space gap tolerance joins them into one run wide
        /// enough to pass. `detectStaves` then fits its five-line window
        /// to six lines, picks the top five, and every pitch on that
        /// staff moves two steps while measure counts, note counts and
        /// durations all stay perfect.
        @Test func aRowOfLedgerLinesIsNotBridgedIntoAStaffLine() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            // 1.6-space marks (19px) every 31px — an 11px gap, inside the
            // 12px tolerance — spanning 400px, well over the 50pt gate.
            for i in 0 ..< 13 {
                let x0 = 100 + i * 31
                RasterTestBitmaps.hLine(&bmp, y: 150, x0: x0, x1: x0 + 19, thickness: 1)
            }
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.filter { $0.rect.width > 50 }.isEmpty)
        }

        /// …while a genuinely broken staff line, whose ink fraction stays
        /// high, must still survive. Without this the fix above would
        /// simply undo the gap tolerance it is guarding.
        @Test func aMostlyInkedLineStillSurvivesTheInkFractionGate() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            for chunk in 0 ..< 6 {
                let x0 = 45 + chunk * 135
                RasterTestBitmaps.hLine(&bmp, y: 150, x0: x0, x1: x0 + 125, thickness: 1)
            }
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count(where: { $0.rect.width > 50 }) == 1)
        }

        /// A gap WIDER than the tolerance must still break the line —
        /// otherwise the merge would reach across a system and invent a
        /// staff line spanning two of them.
        @Test func aGapWiderThanTheToleranceStillBreaksTheLine() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 40, x1: 380, thickness: 1)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 520, x1: 860, thickness: 1)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 2)
        }

        /// The y of every emitted segment must be in PDF page space —
        /// y-up from the bottom — so the page's TOPMOST line has the
        /// LARGEST y. The top staff line sits at raster row 120 of a
        /// 300px-tall page at 300dpi, so its page y is
        /// (300 − 120) × 72/300 = 43.2pt, and the bottom line (row 168)
        /// is at 31.68pt. Emitting pixels here instead would be silent:
        /// the layout still looks plausible, upside down.
        @Test func segmentsAreEmittedInPageSpaceNotPixels() {
            let bmp = Self.page()
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            let ys = segs.map { Double($0.rect.midY) }.sorted()
            #expect(abs((ys.last ?? 0) - 43.2) < 0.5)
            #expect(abs((ys.first ?? 0) - 31.68) < 0.5)
        }

        /// Segments carry MEASURED ink thickness, not the vector path's
        /// raw `w` operand (which is ~12.9pt for a staff line drawing
        /// 0.9pt of ink). Nothing downstream gates staff lines on it, but
        /// `classifyByVerticals` reads it with an absolute threshold, so
        /// the unit divergence is recorded rather than hidden.
        @Test func lineWidthIsMeasuredInkThickness() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 40, x1: 860, thickness: 3)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 1)
            #expect(abs(Double(segs[0].lineWidth) - 3 * 72.0 / 300.0) < 0.05)
        }
    }
#endif
