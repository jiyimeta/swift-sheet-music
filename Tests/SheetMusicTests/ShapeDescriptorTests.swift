#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    #if os(macOS)
        import CoreText
        import SheetMusicLayoutApple
    #endif

    struct ShapeDescriptorTests {
        /// N horizontal bars stacked vertically — a stand-in for the N flags
        /// of a rest or a beamed flag glyph. Growing the bounding box by
        /// 20pt per bar is a reasonable proxy for how the box actually grows
        /// in Bravura's real rest family (rest8th height 425 -> rest64th
        /// height 1183 across 4 steps, ratio ~2.8, ~1.6 per step). This
        /// helper is coverage for `verticalProjectionPeaks` only —
        /// `nearerForSameFamilyThanAcrossFamilies` below uses REAL Bravura
        /// outlines rather than this stand-in, because a synthetic
        /// same-family/cross-family distance comparison turned out NOT to be
        /// trustworthy evidence about the descriptor (see task-10-report.md
        /// for the retraction: an earlier version of this file used a
        /// fixed-envelope variant of `bars(_:)` that forced aspectRatio to
        /// exactly 1.0 for every family member, which is not representative
        /// of real notation glyphs and was itself measured against real
        /// Bravura outlines to be false).
        private func bars(_ n: Int) -> CGPath {
            let path = CGMutablePath()
            for i in 0 ..< n {
                path.addRect(CGRect(x: 0, y: CGFloat(i) * 20, width: 60, height: 8))
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

        #if os(macOS)
            /// Rasterize a real Bravura SMuFL glyph outline via the same
            /// CTFont path the codebase already uses for glyph metrics
            /// (`AppleFontMetricsProvider.glyphPathBoundingBox`). Returns nil
            /// if the font can't be registered/resolved in this environment
            /// so the caller can skip gracefully instead of failing CI.
            private func bravuraGlyphPath(
                codepoint: UInt16, size: CGFloat = 1000,
            ) -> CGPath? {
                guard #available(macOS 15.0, *), BravuraFont.register else { return nil }
                let ctFont = CTFontCreateWithName(
                    BravuraFont.familyName as CFString, size, nil,
                )
                var unichars: [UniChar] = [codepoint]
                var glyphs: [CGGlyph] = [0]
                guard CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 1),
                      glyphs[0] != 0
                else { return nil }
                return CTFontCreatePathForGlyph(ctFont, glyphs[0], nil)
            }

            /// Validates the descriptor's core design claim — same-family
            /// glyphs measure nearer than cross-family ones — against REAL
            /// glyph outlines: Bravura rest8th (U+E4E6) vs rest16th (U+E4E7),
            /// same family and differing only in flag count, vs
            /// noteheadBlack (U+E0A4), an unrelated glyph family. Skips if
            /// Bravura can't be resolved in this environment. See
            /// task-10-report.md for the measured distances — this replaces
            /// an earlier synthetic-fixture version of this test that was
            /// found (by a reviewer measuring real Bravura outlines) not to
            /// be representative.
            @Test func nearerForSameFamilyThanAcrossFamilies() {
                guard
                    let rest8thPath = bravuraGlyphPath(codepoint: 0xE4E6),
                    let rest16thPath = bravuraGlyphPath(codepoint: 0xE4E7),
                    let noteheadPath = bravuraGlyphPath(codepoint: 0xE0A4)
                else { return }
                let rest8th = makeDescriptor(path: rest8thPath)
                let rest16th = makeDescriptor(path: rest16thPath)
                let notehead = makeDescriptor(path: noteheadPath)
                let sameFamily = rest8th.distance(to: rest16th)
                let crossFamily = rest8th.distance(to: notehead)
                #expect(sameFamily < crossFamily)
            }

            /// The em-relative features are STAFF-relative by the SMuFL spec
            /// (em square == staff height == four spaces), which is what makes
            /// them hold across font designs where the raster silhouette does
            /// not. Pins the reference values the cascade relies on: a plain G
            /// clef is ~7 spaces tall, the same clef with an octave digit ~7.9,
            /// and the whole/half rest pair differs ONLY in where its box sits
            /// relative to the baseline.
            @Test func emFeaturesMeasureTheGlyphAgainstTheStaff() {
                guard let clefG = bravuraGlyphPath(codepoint: 0xE050),
                      let clefG8vb = bravuraGlyphPath(codepoint: 0xE052),
                      let restWhole = bravuraGlyphPath(codepoint: 0xE4E3),
                      let restHalf = bravuraGlyphPath(codepoint: 0xE4E4)
                else { return }
                let g = makeDescriptor(path: clefG)
                let g8vb = makeDescriptor(path: clefG8vb)
                #expect(abs(g.emHeight - 7.0) < 0.2)
                #expect(g8vb.emHeight - g.emHeight > 0.5)
                #expect(g.emBottom - g8vb.emBottom > 0.5) // the digit hangs below

                let whole = makeDescriptor(path: restWhole)
                let half = makeDescriptor(path: restHalf)
                #expect(abs(whole.emHeight - half.emHeight) < 0.05) // same box
                #expect(half.emBottom - whole.emBottom > 0.4) // different place
            }
        #endif
    }
#endif
