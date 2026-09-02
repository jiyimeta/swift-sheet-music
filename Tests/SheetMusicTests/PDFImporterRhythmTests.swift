#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct PDFImporterRhythmTests {
        // MARK: - Fixtures

        private func notehead(
            x: CGFloat, y: CGFloat = 500,
            kind: SMuFLSemantic = .noteheadBlack,
            midi: Int = 71,
        ) -> (ClassifiedGlyph, PDFImporter.DecodedPitch) {
            let g = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: kind,
            )
            let dp = PDFImporter.DecodedPitch(
                midi: midi, tpc: 14,
                noteheadX: x, noteheadY: y, glyph: g,
            )
            return (g, dp)
        }

        private func stem(x: CGFloat, yMin: CGFloat, yMax: CGFloat) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(x: x, y: yMin, width: 0, height: yMax - yMin),
                lineWidth: 0.5,
                pageIndex: 0,
            )
        }

        private func flag(
            x: CGFloat, y: CGFloat, kind: SMuFLSemantic,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: kind,
            )
        }

        private func dot(x: CGFloat, y: CGFloat) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .augmentationDot,
            )
        }

        private func restGlyph(
            x: CGFloat, y: CGFloat = 500, duration: NoteDuration,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .rest(duration),
            )
        }

        private func makeMeasure(
            glyphs: [ClassifiedGlyph],
            staffYLines: [CGFloat] = [490, 495, 500, 505, 510],
        ) -> ImportMeasure {
            ImportMeasure(
                xRange: 50 ... 550,
                glyphs: glyphs,
                leadingBarline: nil,
                trailingBarline: nil,
                staffYLines: staffYLines,
            )
        }

        // MARK: - Tests

        @Test func blackNoteheadAloneIsQuarter() {
            let (g, dp) = notehead(x: 100, y: 500)
            let m = makeMeasure(glyphs: [g])
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .quarter)
            #expect(rhythm.first?.chord.notes.count == 1)
            #expect(rhythm.first?.isRest == false)
        }

        @Test func wholeNoteheadIsWhole() {
            let (g, dp) = notehead(x: 100, y: 500, kind: .noteheadWhole)
            let m = makeMeasure(glyphs: [g])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: [],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .whole)
            #expect(rhythm.first?.stemDirection == nil)
        }

        @Test func halfNoteheadIsHalf() {
            let (g, dp) = notehead(x: 100, y: 500, kind: .noteheadHalf)
            let m = makeMeasure(glyphs: [g])
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .half)
        }

        @Test func blackPlusOneFlagIsEighth() {
            let (g, dp) = notehead(x: 100, y: 500)
            // The stem runs up from the notehead to y=530, and the flag glyph's
            // ORIGIN sits AT that bare end. Measured over the 135-score real
            // corpus, 53,058 of the ~54,000 flags sharing a stem's x column are
            // within 0.04 staff spaces of the stem end; the next population is
            // 3.1 sp away and belongs to another note. (This fixture used to
            // put the flag at y=512, calibrated against an `applyFlags` that
            // measured from the NOTEHEAD through a 4…22pt window — a geometry
            // MuseScore does not emit.)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let f = flag(x: 100, y: 530, kind: .flag8thUp)
            let m = makeMeasure(glyphs: [g, f])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .eighth)
        }

        @Test func blackPlusTwoFlagsIsSixteenth() {
            let (g, dp) = notehead(x: 100, y: 500)
            // A combined 16th flag glyph (one glyph carrying both levels) at
            // the stem's bare end, plus a stray 8th flag — the higher level
            // wins. Both sit at the stem end, which is where MuseScore anchors
            // them (see `blackPlusOneFlagIsEighth` for the measurement).
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let f1 = flag(x: 100, y: 530, kind: .flag8thUp)
            let f2 = flag(x: 100, y: 530, kind: .flag16thUp)
            let m = makeMeasure(glyphs: [g, f1, f2])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .sixteenth)
        }

        @Test func blackPlusOneDotIsDottedQuarter() {
            let (g, dp) = notehead(x: 100, y: 500)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            // 1.0 notehead-advance to the right (advance 5). Measured over
            // the real corpus a note's own dot sits at 0.8–1.2 advances and
            // nothing at all sits at 1.3–1.4; this fixture used to place it
            // at 2.0 advances, which is where a LATER note's dot lives.
            let d = dot(x: 105, y: 500)
            let m = makeMeasure(glyphs: [g, d])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == NoteDuration.quarter.dotted(1))
        }

        /// The proportions MuseScore actually engraves an augmentation dot
        /// at, measured over the curated corpus (dotGeometryProbe): the dot
        /// origin sits 0.83–1.22 notehead-advances to the RIGHT and within
        /// 0.25 advances vertically. The 0.9 median is well inside the old
        /// absolute window too — this pins that tightening the window for
        /// staccato (below) does not start dropping real dots.
        @Test func dotAtEngravedProportionsStillDots() {
            let (g, dp) = notehead(x: 100, y: 500)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            // advance 5 ⇒ dx 0.90 adv, dy 0.25 adv.
            let d = dot(x: 104.5, y: 501.25)
            let m = makeMeasure(glyphs: [g, d])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == NoteDuration.quarter.dotted(1))
        }

        /// A STACCATO dot is centred over its notehead, not placed to the
        /// right of it: measured at 0.23–0.25 advances horizontally and
        /// 0.40–0.67 vertically, against 0.83+ / ≤0.25 for a real dot.
        ///
        /// Tier 1 has no semantic for `articStaccatoAbove/Below`, so a
        /// staccato only reaches here as `.augmentationDot` when Tier 4
        /// shape-matching names the round blob — the two glyphs are the
        /// same circle and no classifier can separate them. Rejecting it
        /// is the placement's job, and the old absolute window (dx < 12pt,
        /// dy < 4pt, no lower bound on dx) let it through: 131 staccato
        /// glyphs across the curated corpus, +77 phantom dotted chords on
        /// 君とParadiso alone — each one a note played 1.5× too long.
        @Test func staccatoAboveNoteheadIsNotAnAugmentationDot() {
            let (g, dp) = notehead(x: 100, y: 500)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            // advance 5 ⇒ dx 0.25 adv, dy 0.50 adv — mid-corpus staccato.
            let d = dot(x: 101.25, y: 502.5)
            let m = makeMeasure(glyphs: [g, d])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .quarter)
        }

        /// The same rejection below the notehead (stem-up notes take
        /// `articStaccatoBelow`, U+E4A3 — the more common of the pair in
        /// the corpus, 96 of 131).
        @Test func staccatoBelowNoteheadIsNotAnAugmentationDot() {
            let (g, dp) = notehead(x: 100, y: 500)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let d = dot(x: 101.25, y: 497.5)
            let m = makeMeasure(glyphs: [g, d])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .quarter)
        }

        /// The residual staccato the dx floor alone cannot reject: the dot
        /// belongs to the SECOND notehead (it is centred over it) but sits
        /// at a perfectly dot-like offset from the FIRST one, so the first
        /// note claims it. 12 of the corpus's 131 staccato glyphs land here
        /// (all in 君とParadiso). The owner test — "some notehead has this
        /// dot centred over it, at staccato height" — rejects all 12 and
        /// fires on none of the ~1080 real dots.
        @Test func staccatoCentredOnALaterNoteheadIsNotTheEarlierNotesDot() {
            let (g1, dp1) = notehead(x: 100, y: 500, midi: 71)
            let (g2, dp2) = notehead(x: 108, y: 500, midi: 72)
            let stems = [
                stem(x: 100, yMin: 500, yMax: 530),
                stem(x: 108, yMin: 500, yMax: 530),
            ]
            // g2's staccato: 0.25 advances right of g2, 0.5 above it — but
            // 1.85 advances right of g1 and only 2.5pt up, i.e. inside g1's
            // dot window.
            let d = dot(x: 109.25, y: 502.5)
            let m = makeMeasure(glyphs: [g1, g2, d])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp1, dp2], paths: stems,
            )
            #expect(rhythm.count == 2)
            #expect(rhythm[0].chord.duration == .quarter)
            #expect(rhythm[1].chord.duration == .quarter)
        }

        @Test func twoNoteheadsOneStemFormOneChord() {
            let (g1, dp1) = notehead(x: 100, y: 495, midi: 67)
            let (g2, dp2) = notehead(x: 100, y: 505, midi: 74)
            let stems = [stem(x: 100, yMin: 495, yMax: 525)]
            let m = makeMeasure(glyphs: [g1, g2])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp1, dp2], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.notes.count == 2)
        }

        @Test func twoNoteheadsAdjacentStemsFormTwoChords() {
            let (g1, dp1) = notehead(x: 100, y: 500, midi: 71)
            let (g2, dp2) = notehead(x: 200, y: 500, midi: 72)
            let stems = [
                stem(x: 100, yMin: 500, yMax: 530),
                stem(x: 200, yMin: 500, yMax: 530),
            ]
            let m = makeMeasure(glyphs: [g1, g2])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp1, dp2], paths: stems,
            )
            #expect(rhythm.count == 2)
            #expect(rhythm[0].chord.notes.count == 1)
            #expect(rhythm[1].chord.notes.count == 1)
        }

        @Test func restGlyphProducesRest() {
            let r = restGlyph(x: 100, y: 500, duration: .quarter)
            let m = makeMeasure(glyphs: [r])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [], paths: [],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.notes.isEmpty == true)
            #expect(rhythm.first?.chord.duration == .quarter)
            #expect(rhythm.first?.isRest == true)
        }
    }
#endif
