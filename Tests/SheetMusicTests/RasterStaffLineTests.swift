#if !os(Android) && !os(WASI)
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

        /// The blade-comb failure `cov_flags` page 1 exposed: a page of
        /// same-pitch 64th figures repeats every flag blade at one y
        /// across the page width, those rows reach 0.4-0.55 of the row
        /// projection's peak, they crossed the old 0.5×peak threshold,
        /// and the estimated spacing collapsed from the staff-line pitch
        /// to the BLADE pitch — taking every sp-denominated constant
        /// downstream with it (533 verticals emitted against ~230, dur
        /// 48 / pitch 46 on the render). The staff lines are still the
        /// widest rows on the page; the estimator has to prefer them.
        @Test func repeatedShortInkRowsDoNotCollapseTheSpacing() {
            var bmp = Self.page(spacingPx: 12)
            // A comb of 12 rows at 55% of the staff-line width, pitched
            // at 8 px — sized to cross the old 0.5×peak threshold and
            // stay under the shipped fraction.
            for i in 0 ..< 12 {
                RasterTestBitmaps.hLine(
                    &bmp, y: 200 + 8 * i, x0: 100, x1: 545, thickness: 1,
                )
            }
            let mask = RasterPage.binarize(bmp)
            let spacing = RasterPage.estimateStaffSpacingPx(mask)
            #expect(abs((spacing ?? 0) - 12) <= 1)
            // Break-and-restore: the OLD threshold on the SAME mask
            // reproduces the collapse, so the shipped fraction is proven
            // load-bearing rather than decorative.
            let broken = RasterPage.estimateStaffSpacingPx(mask, peakFraction: 0.5)
            #expect(abs((broken ?? 0) - 8) <= 1)
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

        /// A DENSE row of ledger lines defeats the ink-fraction gate —
        /// the marks nearly touch, so the bridged run really is almost
        /// solid ink — and is rejected on width instead: a staff line
        /// spans its system, and every staff line on a page is about as
        /// wide as every other.
        ///
        /// Measured on `tex_0064`: eight such rows a staff space apart,
        /// 91pt wide, between two real staves whose lines are 486–510pt.
        /// `detectStaves` fitted a five-line window to eight lines and
        /// reported FOUR staves on a three-staff page.
        @Test func aDenseLedgerRowIsRejectedOnWidthNotInk() {
            var bmp = RasterTestBitmaps.blank(widthPx: 1200, heightPx: 400, dpi: 300)
            // Real staff: five lines spanning 1000px.
            for i in 0 ..< 5 {
                RasterTestBitmaps.hLine(
                    &bmp, y: 100 + i * 12, x0: 100, x1: 1100, thickness: 1,
                )
            }
            // Dense ledger rows: 19px marks 2px apart — solid enough to
            // clear the ink-fraction gate — spanning only 190px.
            for row in 0 ..< 3 {
                for i in 0 ..< 9 {
                    let x0 = 300 + i * 21
                    RasterTestBitmaps.hLine(
                        &bmp, y: 250 + row * 12, x0: x0, x1: x0 + 19, thickness: 1,
                    )
                }
            }
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 5)
            #expect(segs.allSatisfy { $0.rect.width > 200 })
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

        /// INK THAT MERGES INTO A LINE MUST NOT MOVE THE LINE.
        ///
        /// Where a beam, a slur or a dense row of noteheads sits against
        /// a staff line, the rows beside the line also produce a run wide
        /// enough to clear the 50pt gate, and `blobs` merges them into the
        /// line's blob — on ONE side only. Taking the blob's yTop/yBottom
        /// midpoint then reports the line several raster rows away from
        /// where its ink actually is.
        ///
        /// That is not a cosmetic error. `pathDetectedStaves` gates a
        /// five-line group on `gapCV(ys) < 0.1`, so one displaced line
        /// among five costs the WHOLE staff: measured on v2-eval, 27 of
        /// 574 staves were dropped with all five of their lines emitted
        /// and exactly one of them off by 0.8–1.3pt against a 4.56pt
        /// spacing.
        ///
        /// Here the line is 820px wide and the merged block only 320px,
        /// five rows of it, so the midpoint lands 2.5 rows (0.6pt at
        /// 300dpi) below the ink.
        @Test func mergedInkDoesNotDragTheLineCentre() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 40, x1: 860, thickness: 1)
            RasterTestBitmaps.hLine(&bmp, y: 151, x0: 300, x1: 620, thickness: 5)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 1)
            // Row 150 of a 300px page at 300dpi is page y 36.0pt; half a
            // raster row is 0.12pt.
            #expect(abs(Double(segs.first?.rect.midY ?? 0) - 36.0) <= 0.12)
        }

        /// …while a line that is genuinely thick keeps its true centre,
        /// including the half-row offset an even thickness implies. Fixing
        /// the merge above by snapping to one row would lose that.
        ///
        /// Four rows at 150–153 centre on 151.5, page y
        /// (300 − 151.5) × 72/300 = 35.64pt.
        @Test func aThickLineKeepsItsSubRowCentre() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 40, x1: 860, thickness: 4)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 1)
            #expect(abs(Double(segs.first?.rect.midY ?? 0) - 35.64) <= 0.05)
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

        /// Ink NEAR a line's end must not lengthen the line.
        ///
        /// The gap tolerance exists so a broken line comes out as one
        /// segment. At a line's END there is nothing to reconnect to, so
        /// the same tolerance reaches sideways into whatever sits beside
        /// it — measured on v2-eval, the instrument name "Tenor" printed
        /// 4.5pt left of `tex_0017`'s staff bridges into the middle line
        /// on ONE raster row of the two that line occupies.
        ///
        /// The price is a staff, not a line: `detectStaves` builds a
        /// staff's `xRange` from its lines' extents, so the staff starts
        /// 5.9 staff spaces left of where it does and the score gains a
        /// measure. `tex_0017` and `tex_0097` are the only two renders the
        /// `truthStaffLines` bisect wins on, and this is the difference.
        ///
        /// Here: five 2-row lines from x=45, and 16px of foreign ink at
        /// x=20 on the TOP row of the middle line only, 9px from it —
        /// inside the 12px (1.0 space at spacing 12) tolerance.
        @Test func inkBesideALineDoesNotLengthenIt() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            for i in 0 ..< 5 {
                RasterTestBitmaps.hLine(
                    &bmp, y: 120 + i * 12, x0: 45, x1: 855, thickness: 2,
                )
            }
            RasterTestBitmaps.hLine(&bmp, y: 144, x0: 20, x1: 36, thickness: 1)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            // The polluted line is still EMITTED — this trims an extent,
            // it does not drop a line — and starts where its siblings do.
            #expect(segs.count == 5)
            let lefts = segs.map { Double($0.rect.minX) }
            #expect((lefts.max() ?? 0) - (lefts.min() ?? 0) < 0.05)
            // x=45 at 300dpi is page x 10.8pt; x=20 would be 4.8pt.
            #expect(abs((lefts.min() ?? 0) - 10.8) < 0.05)
        }

        /// …while a line whose rows genuinely disagree keeps its full
        /// reach. The trim is an intersection, so without a floor a single
        /// half-width row could halve a real line; the guard caps what it
        /// can take at half the blob.
        ///
        /// Here three rows are all core (each is half the widest) but the
        /// second covers only the left half and the third only the right,
        /// so their intersection with the first is EMPTY. The box wins.
        @Test func aLineWhoseRowsDisagreeKeepsItsBox() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 40, x1: 860, thickness: 1)
            RasterTestBitmaps.hLine(&bmp, y: 151, x0: 40, x1: 450, thickness: 1)
            RasterTestBitmaps.hLine(&bmp, y: 152, x0: 450, x1: 860, thickness: 1)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 1)
            #expect(abs(Double(segs.first?.rect.minX ?? 0) - 40 * 72.0 / 300.0) < 0.05)
            #expect(abs(Double(segs.first?.rect.maxX ?? 0) - 860 * 72.0 / 300.0) < 0.05)
        }

        /// …and an ERODED row does not shorten the line either, which is
        /// the whole reason the trim has a floor.
        ///
        /// A degraded page's rows are too SHORT, not too long, so there
        /// the widest row is the truest one. Measured on v2-eval-frozen, a
        /// floor of 0.5 costs 226 staff lines. Here the second row is
        /// missing its first 100px of 820 — an 0.878 agreement, under
        /// `staffLineCoreSpanFloor` — so the box wins.
        @Test func anErodedRowDoesNotShortenTheLine() {
            var bmp = RasterTestBitmaps.blank(widthPx: 900, heightPx: 300, dpi: 300)
            RasterTestBitmaps.hLine(&bmp, y: 150, x0: 40, x1: 860, thickness: 1)
            RasterTestBitmaps.hLine(&bmp, y: 151, x0: 140, x1: 860, thickness: 1)
            let mask = RasterPage.binarize(bmp)
            let segs = RasterPage.staffLineSegments(
                mask, spacingPx: 12, transform: Self.transform(bmp), pageIndex: 0,
            )
            #expect(segs.count == 1)
            #expect(abs(Double(segs.first?.rect.minX ?? 0) - 40 * 72.0 / 300.0) < 0.05)
        }
    }
#endif
