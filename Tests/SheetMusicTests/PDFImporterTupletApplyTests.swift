#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct PDFImporterTupletApplyTests {
        static func note(
            _ duration: NoteDuration, x: CGFloat, pitch: Int = 60,
            stemDirection: StemDirection? = nil,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(
                    duration: duration,
                    notes: [Note(pitch: pitch, tpc: 14)],
                ),
                x: x, y: 0,
                stemDirection: stemDirection,
            )
        }

        static func rest(_ duration: NoteDuration, x: CGFloat) -> RhythmElement {
            RhythmElement(
                chord: Chord(duration: duration, notes: []),
                x: x, y: 0,
            )
        }

        static func mark(
            _ range: ClosedRange<CGFloat>,
            anchor: PDFImporter.TupletMark.Anchor = .bracket,
            digitCenterX: CGFloat? = nil,
        ) -> PDFImporter.TupletMark {
            PDFImporter.TupletMark(
                xRange: range,
                normal: 2, actual: 3,
                digitCenterX: digitCenterX ?? (range.lowerBound + range.upperBound) / 2,
                digitOrigin: .zero,
                anchor: anchor,
            )
        }

        /// 君とParadiso p0 m0: a bracketed triplet quarter + eighth. The
        /// members are NOT equal and NOT beamed, which is exactly what the
        /// old run-based detector could never see.
        @Test func bracketScalesHeterogeneousMembers() {
            let elements = [
                Self.note(.half, x: 109.5),
                Self.note(.quarter, x: 176.6),
                Self.note(.eighth, x: 200.4),
            ]
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(178.2 ... 206.4)],
                spatium: 3.35,
            )
            #expect(out[0].chord.duration == .half)
            #expect(out[0].inTuplet == false)
            #expect(out[1].chord.duration == .fraction(
                Fraction(numerator: 1, denominator: 6),
            ))
            #expect(out[2].chord.duration == .fraction(
                Fraction(numerator: 1, denominator: 12),
            ))
            #expect(out[1].inTuplet)
            #expect(out[2].inTuplet)
        }

        /// A run whose scaled sum is not a clean note value is not a
        /// tuplet: two straight eighths scale to 1/6, which no written
        /// value spells.
        @Test func unscalableRunIsLeftAlone() {
            let elements = [
                Self.note(.eighth, x: 100),
                Self.note(.eighth, x: 120),
            ]
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(95 ... 125)],
                spatium: 5,
            )
            #expect(out[0].chord.duration == .eighth)
            #expect(out[1].chord.duration == .eighth)
            #expect(out.allSatisfy { !$0.inTuplet })
        }

        /// A bracket may enclose a rest; it is a member and scales too.
        @Test func restInsideABracketIsAMember() {
            let elements = [
                Self.note(.eighth, x: 100),
                Self.rest(.eighth, x: 120),
                Self.note(.eighth, x: 140),
            ]
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(95 ... 145)],
                spatium: 5,
            )
            let twelfth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 12),
            )
            #expect(out.allSatisfy { $0.chord.duration == twelfth })
            #expect(out.allSatisfy { $0.inTuplet == true })
        }

        /// THE REGRESSION GUARD for `PDFImporter.beamMemberSpan`. A beam's
        /// drawn x-range ends flush with its outermost stems only in a
        /// VECTOR PDF; a raster-fitted slab stops INSIDE them, because the
        /// columns where its own end stems stand carry merged beam + stem
        /// ink and land on no ladder rung. `beamWindow` used to read that
        /// range raw and hand it here as the member window — where the
        /// UPPER bound gets no slack at all, on the explicit assumption
        /// that the rightmost member sits at or inside the mark's right
        /// edge.
        ///
        /// Losing one member does not truncate the tuplet, it DELETES it:
        /// the surviving two sixteenths sum to 1/8, ×2/3 = 1/12, which
        /// `cleanScale` refuses, so the mark is discarded and the bar falls
        /// through to rhythm reconciliation. That is why the corpus effect
        /// (v2-eval durP50 85.5 → 88.0, durMean 74.5 → 76.4, ten renders up
        /// and none down) is so much larger than the 807 stem inclusions
        /// the raw range loses — and why it closed the beam oracle's whole
        /// remaining gap (`truthBeams` 88.0 / 76.6).
        ///
        /// STEM-DOWN members on purpose: that is the one direction
        /// `windowIndices` grants no slack on either side, so this test
        /// depends on the pad and on nothing else.
        @Test func aBeamTruncatedInsideItsOwnEndStemsKeepsTheOuterMembers() {
            let marks = PDFImporter.detectTupletMarks(
                texts: [PDFImporterTupletMarkTests.digit("3", x: 461.16, y: 126.1)],
                paths: PDFImporterTupletMarkTests.truncatedDrumBeams,
                staffYLines: PDFImporterTupletMarkTests.drumYLines,
                xRange: PDFImporterTupletMarkTests.drumCellX,
                pageIndex: 0,
            )
            #expect(marks.count == 1)
            guard let mark = marks.first else { return }
            let elements = [457.3, 462.6, 467.9].map {
                Self.note(.sixteenth, x: CGFloat($0), stemDirection: .down)
            }
            let out = PDFImporter.applyTupletMarks(
                elements: elements, marks: [mark], spatium: 2.83,
            )
            let twentyFourth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 24),
            )
            #expect(out.allSatisfy { $0.chord.duration == twentyFourth })
            // `== true` rather than a bare `\.inTuplet` keypath: SwiftFormat
            // rewrites the closure to the keypath, and `#expect`'s macro then
            // cannot prove the call is non-throwing. Same shape as
            // `bracketedTripletQuarterPlusEighthScales` above.
            #expect(out.allSatisfy { $0.inTuplet == true })
        }

        /// Now_is_the_time p4 m91: the beam window holds five sixteenths
        /// but only the first three are the triplet. Runs of two (1/12) and
        /// four (1/6) fail the clean-sum gate; the three-note run wins.
        @Test func beamWindowPicksTheCleanRunNearestTheDigit() {
            let xs: [CGFloat] = [453.9, 459.1, 464.3, 469.4, 476.4]
            let elements = xs.map { Self.note(.sixteenth, x: $0) }
            let out = PDFImporter.applyTupletMarks(
                elements: elements,
                marks: [Self.mark(
                    457.3 ... 467.9, anchor: .beam, digitCenterX: 462.59,
                )],
                spatium: 2.83,
            )
            let twentyFourth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 24),
            )
            #expect(out[0].chord.duration == twentyFourth)
            #expect(out[1].chord.duration == twentyFourth)
            #expect(out[2].chord.duration == twentyFourth)
            #expect(out[3].chord.duration == .sixteenth)
            #expect(out[4].chord.duration == .sixteenth)
        }

        /// Pins `tupletWindowSlackSpatia` from above: a dotted-16th
        /// distractor sits 5.3sp before a bracketed 16th-triplet — just
        /// OUTSIDE the 1.25sp slack (deficit 5.3 > 5.0 at spatium 4), so it
        /// must stay excluded and unscaled. This is also the false-
        /// positive shape the reviewer flagged: were the distractor swept
        /// in, 3/32 + 3/16 = 9/32, ×2/3 = 3/16 (a clean dotted eighth) —
        /// the clean-sum gate would NOT catch the over-reach, only the
        /// slack's magnitude does.
        @Test func distractorJustOutsideSlackStaysUnscaled() {
            let dottedSixteenth = NoteDuration.sixteenth.dotted(1)
            let distractor = Self.note(
                dottedSixteenth, x: 194.7, stemDirection: .up,
            )
            let members = [202.0, 206.0, 210.0].map {
                Self.note(.sixteenth, x: CGFloat($0), stemDirection: .up)
            }
            let out = PDFImporter.applyTupletMarks(
                elements: [distractor] + members,
                marks: [Self.mark(200 ... 212)],
                spatium: 4,
            )
            #expect(out[0].chord.duration == dottedSixteenth)
            #expect(out[0].inTuplet == false)
            let twentyFourth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 24),
            )
            #expect(out[1].chord.duration == twentyFourth)
            #expect(out[2].chord.duration == twentyFourth)
            #expect(out[3].chord.duration == twentyFourth)
            #expect(out[1 ... 3].allSatisfy { $0.inTuplet == true })
        }

        /// A straight eighth sits 1sp (< the 1.25sp slack) before a
        /// bracketed eighth-triplet. The widened window legitimately pulls
        /// it in (deficit 4 < slack 5 at spatium 4), but the 4-note sum
        /// (1/2 × 2/3 = 1/3) fails the clean-sum gate — unlike the
        /// previous test, there is no coincidental clean value. `.bracket`
        /// must retry with the strict window and recover the authoritative
        /// 3-note triplet rather than dropping the mark entirely.
        @Test func bracketRetriesWithTheStrictWindowWhenSlackOverreaches() {
            let distractor = Self.note(.eighth, x: 296, stemDirection: .up)
            let members = [302.0, 308.0, 314.0].map {
                Self.note(.eighth, x: CGFloat($0), stemDirection: .down)
            }
            let out = PDFImporter.applyTupletMarks(
                elements: [distractor] + members,
                marks: [Self.mark(300 ... 320)],
                spatium: 4,
            )
            #expect(out[0].chord.duration == .eighth)
            #expect(out[0].inTuplet == false)
            let twelfth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 12),
            )
            #expect(out[1].chord.duration == twelfth)
            #expect(out[2].chord.duration == twelfth)
            #expect(out[3].chord.duration == twelfth)
            #expect(out[1 ... 3].allSatisfy { $0.inTuplet == true })
        }

        /// Pins `windowIndices`' `.down` branch: unlike a stem-up (or
        /// direction-unknown) note, a stem-down note's `RhythmElement.x` is
        /// already at its own stem — the notehead sits to the stem's
        /// RIGHT — so it gets no leftward slack in either widened or
        /// strict membership tests. A stem-down distractor sits only
        /// 0.25sp left of `xRange.lowerBound` — well inside the 1.25sp
        /// slack `windowIndices` grants a stem-up note — and must still be
        /// excluded.
        ///
        /// The distractor is a DOTTED eighth (3/16), not a plain sixteenth
        /// like the other distractor fixtures, so that if it were wrongly
        /// swept into the widened window, the 4-element sum (3 straight
        /// eighths + one dotted eighth = 9/16) would ITSELF scale to a
        /// clean value (9/16 × 2/3 = 3/8, a dotted quarter) and pass the
        /// clean-sum gate on the first try — meaning `applyBracket` would
        /// never reach its strict-window retry, which (independent of the
        /// `.down` branch) would have excluded the distractor anyway since
        /// its retry slack is always 0. A plain-sixteenth distractor does
        /// NOT have this property (its 4-note sum lands on the same
        /// unclean 1/6 as `unscalableRunIsLeftAlone`) and so is rescued by
        /// that retry regardless of whether the `.down` branch exists — it
        /// would NOT catch a regression here.
        ///
        /// Proven load-bearing: with the `.down` branch deleted (folding
        /// it into the general slack-on-lower-bound-only case), this test
        /// goes red — the distractor is wrongly admitted, scaled from a
        /// dotted eighth to a plain eighth, and marked `inTuplet`. The
        /// other stem-down fixtures in this file
        /// (`bracketRetriesWithTheStrictWindowWhenSlackOverreaches`'s
        /// members, `restInsideABracketIsAMember`'s notes) never place a
        /// stem-down element outside the strict span, so they stay green
        /// even with the branch deleted.
        @Test func stemDownDistractorJustOutsideTheSpanGetsNoSlack() {
            let dottedEighth = NoteDuration.eighth.dotted(1)
            let distractor = Self.note(dottedEighth, x: 199, stemDirection: .down)
            let members = [202.0, 206.0, 210.0].map {
                Self.note(.eighth, x: CGFloat($0), stemDirection: .down)
            }
            let out = PDFImporter.applyTupletMarks(
                elements: [distractor] + members,
                marks: [Self.mark(200 ... 212)],
                spatium: 4,
            )
            #expect(out[0].chord.duration == dottedEighth)
            #expect(out[0].inTuplet == false)
            let twelfth = NoteDuration.fraction(
                Fraction(numerator: 1, denominator: 12),
            )
            #expect(out[1].chord.duration == twelfth)
            #expect(out[2].chord.duration == twelfth)
            #expect(out[3].chord.duration == twelfth)
            #expect(out[1 ... 3].allSatisfy { $0.inTuplet == true })
        }

        /// 君とParadiso p0 m0's real overflow (half + straight quarter +
        /// straight eighth = 7/8 against a 3/4 bar) is already fully
        /// resolved by `applyTupletMarks` alone: once the quarter/eighth
        /// are rescaled to 1/6 + 1/12, the voice sums to exactly 3/4 and
        /// `reconcileMeasureDurations` returns at INVARIANT 1 (line ~148)
        /// without ever reaching the candidate-index loop this task
        /// guards. So that exact bar cannot exercise the guard, and is not
        /// a useful regression case for it.
        ///
        /// This constructs the case that DOES exercise it: a residual
        /// error elsewhere in the same voice leaves the bar unbalanced
        /// even after scaling, AND — the part that makes the guard's
        /// absence actually observable — the tuplet member's own
        /// single-note repair target happens to also be a legal
        /// `NoteDuration` (`.half`), the same value the true fix wants for
        /// the neighbour. Both notes' noteheads are marked hollow so the
        /// unrelated notehead-shape guard (`RhythmReconcile.swift`, "never
        /// inflate a filled note to a half-or-longer value") doesn't
        /// separately block either candidate and confound this test with a
        /// different guard. The tuplet member is marked low-confidence so
        /// the *existing* tie-break (spacing-residual tie → prefer
        /// low-confidence) deterministically prefers it over the neighbour
        /// pre-fix — reproducing the failure mode this task closes: the
        /// pass "repairs" evidence-backed tuplet data instead of the note
        /// that is actually wrong.
        @Test func reconciliationRepairsTheNeighbourNotTheTupletMember() {
            var elements = [
                Self.note(.quarter, x: 100),
                Self.note(.fraction(Fraction(numerator: 1, denominator: 4)), x: 110),
            ]
            elements[0].noteheadIsFilled = false
            elements[1].tupletRatio = (normal: 2, actual: 3)
            elements[1].noteheadIsFilled = false
            elements[1].lowConfidenceDuration = true
            let out = PDFImporter.reconcileMeasureDurations(
                elements: elements,
                timeSignature: TimeSignature(numerator: 3, denominator: 4),
                spatium: 3.35,
            )
            #expect(out[0].chord.duration == .half)
            #expect(out[1].chord.duration == .fraction(
                Fraction(numerator: 1, denominator: 4),
            ))
        }

        /// Now_is_the_time: a tuplet number drawn above a LOWER staff's
        /// beam falls inside the UPPER staff's lyric band, where it was
        /// being attached as the syllable "3" (measured: 9 spurious lyric
        /// tokens on part 4). Once a mark claims the digit it must be
        /// excluded from the lyric pool.
        @Test func aClaimedTupletDigitIsNotAlsoALyric() {
            let staffYLines: [CGFloat] = [498.3, 501.6, 505.0, 508.3, 511.7]
            let elements = [Self.note(.quarter, x: 120)]
            let digit = TextGlyph(
                text: "3",
                fontName: "FreeSerif",
                fontSize: 6,
                origin: CGPoint(x: 119, y: 492.0),
                // `.zero`, matching production: `TextGlyph.bbox` is never
                // populated by the content-stream walker (see its doc
                // comment in Internal.swift), and `attachLyrics` never reads
                // it — a hand-set bbox here would exercise a shape no real
                // parse ever produces without changing what this test
                // covers.
                bbox: .zero,
                pageIndex: 0,
            )
            let kept = PDFImporter.attachLyrics(
                elements: elements, texts: [digit],
                staffYLines: staffYLines, pageIndex: 0,
                xRange: 100 ... 200,
            )
            #expect(kept[0].chord.lyrics.count == 1)

            let dropped = PDFImporter.attachLyrics(
                elements: elements, texts: [digit],
                staffYLines: staffYLines, pageIndex: 0,
                xRange: 100 ... 200,
                excludingOrigins: [digit.origin],
            )
            #expect(dropped[0].chord.lyrics.isEmpty)
        }
    }
#endif
