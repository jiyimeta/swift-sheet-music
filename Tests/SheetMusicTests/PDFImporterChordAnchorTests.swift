#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// What a chord's decode may and may not read off ONE of its noteheads.
    ///
    /// Stem direction and dot count were both anchored on the cluster's
    /// "lead" — the first unconsumed notehead `decodeRhythm` walks into,
    /// i.e. the lowest one under the canonical stream order. For STEM
    /// DIRECTION that anchor is genuinely wrong on a wide chord, and the
    /// first test below is the case; it is fixed.
    ///
    /// FOR DOTS IT IS NOT WRONG, and three attempts to "fix" it each
    /// measured worse on the 141-score corpus (nearest-mate ownership: 1
    /// score worse; distinct dot columns: 6 worse, one of them dur% 99→95;
    /// max-over-mates: rejected at design time). The reason is upstream, in
    /// `rendering/score/chordlayout.cpp`, and it makes the lead anchor exact
    /// rather than lucky:
    ///
    /// - `int dots = chord->dots()` (:3139) — the dot COUNT is a property of
    ///   the chord, and every notehead is dotted at the chord's shared
    ///   `dotPosX()`. So any notehead's own dots already give the chord's
    ///   level.
    /// - `placeDots` (:2468-2507) never leaves two notes' dots on one staff
    ///   step, so two noteheads' dots are ≥ 1sp ≈ 7pt apart vertically —
    ///   outside the `dy < 4` window, which admits only a note's own dots
    ///   (≤ 0.5sp).
    /// - `conflict = (std::abs(prevLine - line) < 2)` (:2368) mirrors one
    ///   head of a SECOND to the other side of the stem, ~1.07sp away, so
    ///   two noteheads never share an x-column either.
    ///
    /// Fixtures that put a second's two heads at one x, or dot only one
    /// notehead of a chord, therefore describe geometry MuseScore cannot
    /// emit. Three such fixtures were written here and deleted: they did not
    /// document a defect, they documented a false model of one, and the next
    /// reader would have been steered into a fourth attempt. The real defect
    /// in this area is the last test below.
    @MainActor struct PDFImporterChordAnchorTests {
        private func notehead(
            x: CGFloat, y: CGFloat, midi: Int,
        ) -> (ClassifiedGlyph, PDFImporter.DecodedPitch) {
            let g = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .noteheadBlack,
            )
            return (g, PDFImporter.DecodedPitch(
                midi: midi, tpc: 14, noteheadX: x, noteheadY: y, glyph: g,
            ))
        }

        private func stem(x: CGFloat, yMin: CGFloat, yMax: CGFloat) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(x: x, y: yMin, width: 0, height: yMax - yMin),
                lineWidth: 0.5, pageIndex: 0,
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

        private func measure(_ glyphs: [ClassifiedGlyph]) -> ImportMeasure {
            ImportMeasure(
                xRange: 50 ... 550, glyphs: glyphs,
                leadingBarline: nil, trailingBarline: nil,
                staffYLines: [490, 495, 500, 505, 510],
            )
        }

        // MARK: - Stem direction

        /// A DOWN-stem chord wide enough that its stem does not reach far
        /// below the lowest notehead.
        ///
        /// MuseScore sizes a chord's stem from the far notehead plus about a
        /// space, so a wide chord's stem barely clears the near one. Here the
        /// stem hangs from the TOP notehead (y=512) down to y=486, i.e. 10pt
        /// below the bottom notehead (y=496) and 0pt above the top one — an
        /// unambiguous down-stem. Its midY is 499, which is ABOVE the bottom
        /// notehead, so an anchor on the lowest notehead reads `.up`.
        ///
        /// That matters: `voiceFor` maps `.up` to voice 1 and `.down` to
        /// voice 2, so a wrong direction moves the chord into the wrong voice.
        @Test func aWideDownStemChordIsNotReadAsStemUp() {
            let (low, lowPitch) = notehead(x: 100, y: 496, midi: 71)
            let (high, highPitch) = notehead(x: 100, y: 512, midi: 76)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([low, high]), decoded: [lowPitch, highPitch],
                paths: [stem(x: 100, yMin: 486, yMax: 512)],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.notes.count == 2)
            #expect(rhythm.first?.stemDirection == .down)
        }

        /// The mirror case, which the current anchor happens to get right —
        /// pinned so a fix for the one above cannot simply invert the bug.
        @Test func aWideUpStemChordIsStillReadAsStemUp() {
            let (low, lowPitch) = notehead(x: 100, y: 496, midi: 71)
            let (high, highPitch) = notehead(x: 100, y: 512, midi: 76)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([low, high]), decoded: [lowPitch, highPitch],
                paths: [stem(x: 100, yMin: 496, yMax: 522)],
            )
            #expect(rhythm.first?.stemDirection == .up)
        }

        /// A single notehead has no "other" chord-mate, so both the old
        /// lead-anchored rule and a cluster-wide one must agree — in both
        /// directions. This is the regression guard for the overwhelmingly
        /// common case.
        @Test func aSingleNoteheadKeepsItsStemDirection() {
            for (yMin, yMax, expected) in [
                (CGFloat(500), CGFloat(530), StemDirection.up),
                (CGFloat(470), CGFloat(500), StemDirection.down),
            ] {
                let (g, dp) = notehead(x: 100, y: 500, midi: 71)
                let rhythm = PDFImporter.decodeRhythm(
                    measure: measure([g]), decoded: [dp],
                    paths: [stem(x: 100, yMin: yMin, yMax: yMax)],
                )
                #expect(
                    rhythm.first?.stemDirection == expected,
                    "stem \(yMin)…\(yMax)",
                )
            }
        }

        // MARK: - Augmentation dots

        /// The dot rule reads a note's OWN dots, and that is all it needs to
        /// read — see the type doc comment for why anchoring on one notehead
        /// of a chord is exact rather than lucky.
        @Test func aSingleNoteheadKeepsItsDot() {
            let (g, dp) = notehead(x: 100, y: 500, midi: 71)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([g, dot(x: 106, y: 500)]), decoded: [dp],
                paths: [stem(x: 100, yMin: 500, yMax: 530)],
            )
            #expect(rhythm.first?.chord.duration == .quarter.dotted(1))
        }

        // MARK: - The real defect in this area

        /// KNOWN ISSUE: a chord containing a SECOND splits into two
        /// sequential chords.
        ///
        /// This is what the dot investigation actually found, once the
        /// fixtures were made physical. MuseScore mirrors one head of a
        /// second to the other side of the stem — `conflict =
        /// (std::abs(prevLine - line) < 2)` then
        /// `mirror.set_value(...)`, offset `headWidth - stemWidth`
        /// (`rendering/score/chordlayout.cpp:2368, 2404, 2733-2741`), about
        /// 1.07sp. `stemCluster` admits a chord-mate only within
        /// `abs(dx) <= 2.5` pt (`PDFImporter+Rhythm.swift`), which at any
        /// real staff size is far narrower than that offset, so the two
        /// heads never join one cluster.
        ///
        /// The consequence is a NOTE-COUNT error, not a dot error: two
        /// chords where the score has one, and `hasCoincidentOnset`'s 3pt
        /// tolerance does not see them as simultaneous either, so they do
        /// not even become two voices.
        ///
        /// LEFT UNFIXED DELIBERATELY, and the census that decided it is the
        /// point of this comment. Widening the cluster window is a change to
        /// chord and voice assembly on shipped code, so the upper bound on
        /// what it could buy was measured first — over the ground-truth
        /// (`.mscz`) side of the whole corpus, 137 scores:
        ///
        ///     chords                 418,963
        ///     multi-note chords        3,192   (0.76% — these parts are
        ///                                       overwhelmingly monophonic)
        ///     chords with a SECOND       429   (0.10% of all chords)
        ///     with a unison               19
        ///     dotted seconds              18
        ///     scores containing any       21 of 137
        ///
        /// And the 429 are concentrated where they cannot pay: 113 are in a
        /// score with no PDF in the corpus, so it is never scored at all;
        /// 200 more are in `ファンファーレ`, which already reads
        /// `pitch%=99% dur%=99%` with most of its notes hidden from scoring
        /// anyway. What remains is roughly a hundred chords spread over
        /// nineteen scores, several already near-perfect and one
        /// (`疑事無功_piano`, 8%) broken for structural reasons a chord fix
        /// would not touch.
        ///
        /// So the ceiling is a fraction of a percentage point, against a
        /// change that has to relax a window whose narrowness was itself
        /// tuned on measured drum-voice failures. Not worth it — and this
        /// census is exactly the step whose absence cost three rejected
        /// `applyDots` attempts.
        ///
        /// If it is ever revisited: once mirrored heads DO join a cluster,
        /// the dot anchor starts to matter for dotted seconds (the two
        /// halves' dot dx straddle the `minDX` floor and the 12pt cap), so
        /// the anchor question reopens then — with real geometry to design
        /// against.
        @Test func aSecondSplitsIntoTwoChords() {
            // Two heads a staff step apart, the upper mirrored to the right
            // of the shared stem by about one notehead width.
            let (left, leftPitch) = notehead(x: 100, y: 500, midi: 71)
            let (right, rightPitch) = notehead(x: 105, y: 502.5, midi: 72)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([left, right]),
                decoded: [leftPitch, rightPitch],
                paths: [stem(x: 105, yMin: 500, yMax: 530)],
            )
            withKnownIssue("seconds split — see the doc comment") {
                #expect(rhythm.count == 1)
                #expect(rhythm.first?.chord.notes.count == 2)
            }
        }
    }
#endif
