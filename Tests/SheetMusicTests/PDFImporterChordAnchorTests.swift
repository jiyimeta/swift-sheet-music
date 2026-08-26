#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
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

        // MARK: - Chords containing a second

        /// A chord containing a SECOND is ONE chord, even though the engraver
        /// has to draw its two heads in different columns.
        ///
        /// MuseScore mirrors one head of a second to the other side of the
        /// stem — `conflict = (std::abs(prevLine - line) < 2)` then
        /// `mirror.set_value(...)`, offset `headWidth - stemWidth`
        /// (`rendering/score/chordlayout.cpp:2368, 2404, 2733-2741`). So the
        /// two heads of a second NEVER share an x column, and a cluster rule
        /// that demands a shared x cannot ever join them.
        ///
        /// `stemCluster` used to demand exactly that, within `abs(dx) <= 2.5`
        /// pt — narrower than the mirror offset at every real staff size, and
        /// a fixed number of points for a distance that scales with the
        /// staff. The consequence was a NOTE-COUNT error: two chords where
        /// the score has one, and since `hasCoincidentOnset`'s tolerance does
        /// not see them as simultaneous either, they did not even become two
        /// voices.
        ///
        /// THE WINDOW IS MEASURED, not guessed. Over the 135-score real
        /// corpus, every notehead that (a) resolves to the SAME stem as the
        /// cluster's lead and (b) fell outside the old 2.5pt window — 1,312
        /// of them — sits at:
        ///
        ///     |dx| 1.2 sp   980    |dy| 0.50 sp = one staff step (a second)
        ///     |dx| 1.5 sp   266    the same, in a wider-headed font
        ///     |dx| 1.6 sp    48
        ///     |dx| ≥ 1.9 sp  18    (the whole tail)
        ///
        /// so 1.8 sp lies in the gap. The dx spread 1.2 … 1.6 is font
        /// variation in `headWidth - stemWidth`, which is why the window has
        /// to be expressed in staff spaces.
        ///
        /// WHAT KEEPS THE DRUM FIX WORKING is the SAME-STEM condition, not
        /// the x window: a drum downbeat stacks a crash (stem-up) over a kick
        /// (stem-down) at one x, on two different stems, and it is the stem
        /// index that separates them. Over the same corpus 237,751 candidates
        /// outside the old window resolve to a DIFFERENT stem and are still
        /// rejected; only 3 have no stem at all. Widening the x window
        /// therefore cannot re-open the 群青 / 君と drum loss.
        ///
        /// (The earlier census of the ground-truth side — 429 chords with a
        /// second, 0.10% of the corpus's chords — is a statement about THIS
        /// corpus, which is band scores. It is not a statement about whether
        /// the importer needs to read chords: piano and guitar writing is
        /// full of seconds.)
        @Test func aChordContainingASecondStaysOneChord() {
            // The measured geometry: heads one staff step apart (dy 0.5 sp),
            // the upper mirrored to the right of the shared stem by one
            // notehead width (dx 1.2 sp — the corpus's dominant value).
            // `measure` engraves a 5pt staff space.
            let (left, leftPitch) = notehead(x: 100, y: 500, midi: 71)
            let (right, rightPitch) = notehead(x: 106, y: 502.5, midi: 72)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([left, right]),
                decoded: [leftPitch, rightPitch],
                paths: [stem(x: 106, yMin: 500, yMax: 530)],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.notes.count == 2)
        }

        /// Two noteheads at one x on TWO stems stay two chords — the drum
        /// downbeat (crash over kick) the same-stem condition exists for.
        /// Widening the x window must not touch this.
        @Test func twoStemsAtOneXStayTwoChords() {
            let (up, upPitch) = notehead(x: 100, y: 512, midi: 76)
            let (down, downPitch) = notehead(x: 100, y: 496, midi: 60)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([up, down]),
                decoded: [upPitch, downPitch],
                paths: [
                    stem(x: 106, yMin: 512, yMax: 534), // crash, stem-up
                    stem(x: 100, yMin: 474, yMax: 496), // kick, stem-down
                ],
            )
            #expect(rhythm.count == 2)
            #expect(rhythm.allSatisfy { $0.chord.notes.count == 1 })
        }
    }
#endif
