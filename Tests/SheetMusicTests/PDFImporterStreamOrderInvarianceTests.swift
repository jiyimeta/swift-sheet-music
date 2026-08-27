#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// `buildScore` must be a function of its streams' CONTENT, not of their
    /// order.
    ///
    /// WHY THIS IS A HARD REQUIREMENT, not tidiness. A raster front-end fills
    /// the same four `WalkedContent` streams a PDF walker does, but it finds
    /// glyphs on a page — it cannot reproduce a content stream's order. If the
    /// decode depends on that order, the raster path can never agree with the
    /// vector import of the same page, which is what gate P0-G1 asserts over
    /// the whole dataset.
    ///
    /// Measured 2026-08-11 over 2208 renders before the fix:
    /// `exact=1574/2208`, diverging on durations (366), pitches (172), dots
    /// (58), and a tail of voices, tuplets and lyric attachment. This test is
    /// that gate in unit form: it runs in milliseconds, so the invariant can
    /// be iterated on without an hour of MuseScore.
    ///
    /// The fixture is built to CONTAIN TIES, because a fixture without them
    /// passes vacuously — the earlier reverse-order check in
    /// `OMROracleReplayUnitTests` did exactly that for months. Every element
    /// below is placed to collide with another on the key some pass sorts by:
    /// a chord's two noteheads at one x, an accidental and a dot in the same
    /// bar, two beamed notes, a tie arc anchored between equidistant
    /// noteheads, and two text runs on one baseline.
    struct PDFImporterStreamOrderInvarianceTests {
        private static let staffBottom: CGFloat = 400
        private static let lineGap: CGFloat = 8

        private static func y(line: Int) -> CGFloat {
            staffBottom + CGFloat(line) * lineGap
        }

        private static func glyph(
            _ semantic: SMuFLSemantic, x: CGFloat, y: CGFloat,
            advance: CGFloat = 6, renderedSize: CGFloat = 10,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: advance,
                    renderedSize: renderedSize, pageIndex: 0, fontSize: 100,
                ),
                semantic: semantic,
            )
        }

        private static func stem(x: CGFloat, y: CGFloat, height: CGFloat) -> PathSegment {
            PathSegment(
                kind: .vertical, rect: CGRect(x: x, y: y, width: 0, height: height),
                lineWidth: 1.2, pageIndex: 0, quad: nil,
            )
        }

        /// One staff, one bar, deliberately full of ties.
        static func richContent() -> (WalkedContent, [Int: CGSize]) {
            var content = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            for line in 0 ..< 5 {
                content.paths.append(PathSegment(
                    kind: .horizontal,
                    rect: CGRect(x: 50, y: y(line: line), width: 420, height: 0),
                    lineWidth: 0.6, pageIndex: 0, quad: nil,
                ))
            }
            content.glyphs.append(glyph(
                .clefG,
                x: 60,
                y: y(line: 1),
                advance: 8,
                renderedSize: 32,
            ))

            // 1. THE DISCRIMINATING TIE. Two noteheads at ONE x, so the
            //    x-only sort in PDFImporter+Rhythm cannot order them and
            //    whichever lands first becomes the cluster LEAD (the first
            //    unconsumed notehead in that array, `decodeRhythm`'s loop).
            //
            //    The lead anchors the augmentation-dot window: `applyDots`
            //    accepts a dot within `dy < 4` of the LEAD's y. The dot below
            //    sits 3pt from the lower notehead and 5pt from the upper, so
            //    the chord is dotted or not purely according to which
            //    notehead the sort happened to put first — a duration
            //    difference, which is the largest bucket in the real gate's
            //    divergences.
            content.glyphs.append(glyph(.noteheadBlack, x: 120, y: y(line: 2)))
            content.glyphs.append(glyph(.noteheadBlack, x: 120, y: y(line: 3)))
            // dx = 8 = 1.33 advances: an augmentation dot, not a staccato
            // (measured staccato sits at 0.23–0.25 advances, and
            // `isStaccatoOfSomeNotehead` rejects on exactly that).
            content.glyphs.append(glyph(
                .augmentationDot,
                x: 128,
                y: y(line: 2) + 3,
                advance: 3,
                renderedSize: 4,
            ))
            content.paths.append(stem(x: 126, y: y(line: 2), height: 28))

            // 2. An accidental left of a notehead — the accidental pairing
            //    scan resolves an exact-dy tie by first match.
            content.glyphs.append(glyph(.accidentalSharp, x: 172, y: y(line: 2)))
            content.glyphs.append(glyph(.noteheadBlack, x: 186, y: y(line: 2)))
            content.paths.append(stem(x: 192, y: y(line: 2), height: 26))

            // 3. Two beamed notes: the beam is what makes them eighths, and
            //    beam-to-stem attachment resolves exact-distance ties by
            //    arrival order.
            for (i, x) in [CGFloat(250), CGFloat(290)].enumerated() {
                content.glyphs.append(glyph(.noteheadBlack, x: x, y: y(line: 1 + i)))
                content.paths.append(stem(x: x + 6, y: y(line: 1 + i), height: 30))
            }
            let beamRect = CGRect(x: 256, y: y(line: 1) + 28, width: 40, height: 2)
            content.paths.append(PathSegment(
                kind: .beam, rect: beamRect, lineWidth: 0, pageIndex: 0,
                quad: BeamQuad(
                    xRange: beamRect.minX ... beamRect.maxX,
                    topSlope: 0, topIntercept: beamRect.maxY,
                    botSlope: 0, botIntercept: beamRect.minY, pageIndex: 0,
                ),
            ))

            // 4. Two same-pitch noteheads joined by a tie arc. The arc's
            //    endpoint picks its notehead by nearest dx+dy, so two
            //    equidistant candidates are an arrival-order tie.
            for x in [CGFloat(340), CGFloat(390)] {
                content.glyphs.append(glyph(.noteheadBlack, x: x, y: y(line: 2)))
                content.paths.append(stem(x: x + 6, y: y(line: 2), height: 28))
            }
            content.curves.append(CurveArc(
                bbox: CGRect(x: 344, y: y(line: 2) - 8, width: 46, height: 5),
                leftPoint: CGPoint(x: 344, y: y(line: 2) - 4),
                rightPoint: CGPoint(x: 390, y: y(line: 2) - 4),
                pageIndex: 0,
            ))

            // 5. Two text runs sharing a baseline — the epsilon-band row
            //    comparators in +Text and +Lyrics see these as tied.
            for (i, word) in ["la", "lo"].enumerated() {
                content.texts.append(TextGlyph(
                    text: word, fontName: "Helvetica", fontSize: 10,
                    renderedSize: 10,
                    origin: CGPoint(x: 120 + CGFloat(i) * 66, y: staffBottom - 24),
                    bbox: .zero, pageIndex: 0,
                ))
            }
            return (content, [0: CGSize(width: 595, height: 842)])
        }

        private static func build(
            _ content: WalkedContent,
            _ sizes: [Int: CGSize],
        ) throws -> Score {
            try PDFImporter.buildScore(
                pageCount: 1, walked: content, pageSizes: sizes,
                documentAttributes: nil, options: .init(),
            )
        }

        /// SplitMix64 — a seeded generator, because a test that shuffles with
        /// the system RNG reports a different failure every run and cannot be
        /// bisected.
        private struct Seeded: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }

        private static func shuffled(
            _ content: WalkedContent,
            seed: UInt64,
        ) -> WalkedContent {
            var rng = Seeded(state: seed)
            var out = content
            out.glyphs.shuffle(using: &rng)
            out.texts.shuffle(using: &rng)
            out.paths.shuffle(using: &rng)
            out.curves.shuffle(using: &rng)
            return out
        }

        /// THE INVARIANT.
        @Test func buildScoreIsInvariantUnderStreamPermutation() throws {
            let (content, sizes) = Self.richContent()
            let reference = try Self.build(content, sizes)
            for seed in UInt64(1) ... 24 {
                let permuted = try Self.build(Self.shuffled(content, seed: seed), sizes)
                #expect(permuted == reference, "seed \(seed)")
            }
        }

        /// Reversal on its own, kept as the cheapest possible reproduction and
        /// because it is the permutation a label replay most resembles.
        @Test func buildScoreIsInvariantUnderStreamReversal() throws {
            let (content, sizes) = Self.richContent()
            var reversed = content
            reversed.glyphs.reverse()
            reversed.texts.reverse()
            reversed.paths.reverse()
            reversed.curves.reverse()
            #expect(try Self.build(reversed, sizes) == Self.build(content, sizes))
        }

        /// The fixture must actually decode to something, or every assertion
        /// above holds vacuously over an empty score.
        @Test func theFixtureDecodesToNotes() throws {
            let (content, sizes) = Self.richContent()
            let score = try Self.build(content, sizes)
            var notes = 0
            var chordsOfTwo = 0
            for part in score.parts {
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for element in voice.elements {
                                if case let .chord(chord) = element {
                                    notes += chord.notes.count
                                    if chord.notes.count >= 2 { chordsOfTwo += 1 }
                                }
                            }
                        }
                    }
                }
            }
            #expect(notes >= 6, "notes=\(notes)")
            #expect(chordsOfTwo >= 1, "the chord tie is not being built")
        }
    }
#endif
