#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// A chord's stem direction and dot count are properties of the WHOLE
    /// chord, not of whichever notehead happened to be first in the glyph
    /// array.
    ///
    /// Both were anchored on the cluster's "lead" — the first unconsumed
    /// notehead `decodeRhythm` walks into. That made them depend on glyph
    /// order until the streams were canonicalized, and it leaves them
    /// depending on an arbitrary choice even now: the canonical order puts
    /// the LOWEST notehead first, which is the right anchor for an up-stem
    /// chord and the wrong one for a down-stem chord. Measured over the
    /// 141-score corpus, bottom-first beat top-first — but "beats the other
    /// arbitrary choice" is not the same as correct, and these tests pin the
    /// cases where a fixed anchor is simply wrong.
    @MainActor struct PDFImporterChordAnchorTests {
        private static let lineGap: CGFloat = 5

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

        /// A chord of a SECOND puts its two dots close enough together that
        /// BOTH fall inside one notehead's `dy < 4` window — so counting
        /// every dot near the anchor makes a single-dotted chord read as
        /// DOUBLE-dotted, which is a wrong duration rather than a wrong
        /// attachment.
        ///
        /// A dot belongs to exactly one notehead, so the chord's dot LEVEL is
        /// how many dots any single notehead owns — not how many dots are
        /// nearby.
        @Test func aChordOfASecondIsSingleDottedNotDoubleDotted() {
            let (low, lowPitch) = notehead(x: 100, y: 500, midi: 71)
            let (high, highPitch) = notehead(x: 100, y: 502.5, midi: 72)
            let dots = [dot(x: 106, y: 500), dot(x: 106, y: 502.5)]
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([low, high] + dots),
                decoded: [lowPitch, highPitch],
                paths: [stem(x: 100, yMin: 500, yMax: 530)],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .quarter.dotted(1))
        }

        /// And the miss in the other direction: a wide chord whose dots sit
        /// beside their own noteheads, far from the anchor. The anchor sees
        /// nothing within `dy < 4` and the chord loses its dot entirely.
        @Test func aWideChordKeepsTheDotBesideItsFarNotehead() {
            let (low, lowPitch) = notehead(x: 100, y: 496, midi: 71)
            let (high, highPitch) = notehead(x: 100, y: 512, midi: 76)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([low, high, dot(x: 106, y: 512)]),
                decoded: [lowPitch, highPitch],
                paths: [stem(x: 100, yMin: 496, yMax: 522)],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .quarter.dotted(1))
        }

        /// A single notehead's dot is unaffected — the common case again.
        @Test func aSingleNoteheadKeepsItsDot() {
            let (g, dp) = notehead(x: 100, y: 500, midi: 71)
            let rhythm = PDFImporter.decodeRhythm(
                measure: measure([g, dot(x: 106, y: 500)]), decoded: [dp],
                paths: [stem(x: 100, yMin: 500, yMax: 530)],
            )
            #expect(rhythm.first?.chord.duration == .quarter.dotted(1))
        }
    }
#endif
