#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterSMuFLTests {
        @Test func mapsBraceCodepointToBraceSemantic() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE000) == .brace)
        }

        @Test func semanticIsHashableAndDistinguishesCases() {
            let set: Set<SMuFLSemantic> = [
                .brace, .noteheadBlack, .rest(.quarter), .rest(.eighth),
                .unknown(0xE999),
            ]
            #expect(set.count == 5)
            #expect(set.contains(.rest(.quarter)))
            #expect(!set.contains(.rest(.half)))
        }

        @Test func unknownCodepointStillFallsThrough() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE999) == .unknown(0xE999))
        }

        @Test func classifiesNoteheads() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A4) == .noteheadBlack)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A3) == .noteheadHalf)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A2) == .noteheadWhole)
        }

        @Test func classifiesClefs() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE050) == .clefG)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE062) == .clefF)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE05C) == .clefC)
        }

        @Test func classifiesTimeSignatureDigits() {
            for digit in 0 ... 9 {
                let cp = UInt32(0xE080 + digit)
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .timeSignatureDigit(digit))
            }
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE08A) == .timeSignatureCommon)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE08B) == .timeSignatureCutTime)
        }

        @Test func classifiesAccidentals() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE262) == .accidentalSharp)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE260) == .accidentalFlat)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE261) == .accidentalNatural)
        }

        @Test func classifiesFlags() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE240) == .flag8thUp)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE241) == .flag8thDown)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE242) == .flag16thUp)
        }

        @Test func classifiesRestsByDuration() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E3) == .rest(.whole))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E4) == .rest(.half))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E5) == .rest(.quarter))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E6) == .rest(.eighth))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E7) == .rest(.sixteenth))
        }

        /// The whole fermata family, not just `fermataAbove`.
        ///
        /// SMuFL's "Holds and pauses" range opens with fourteen fermata
        /// variants (U+E4C0 fermataAbove … U+E4CD fermataShortHenzeBelow)
        /// and only then turns to breath marks and caesuras, which are
        /// NOT fermatas and have no detector class. Endpoints read out of
        /// MuseScore's own bundled `fonts/smufl/glyphnames.json` +
        /// `ranges.json`, not guessed: the range as a whole is
        /// U+E4C0–U+E4DF, but `breathMarkComma` sits at U+E4CE, so the
        /// fermata block is the contiguous prefix and stops one short of
        /// it.
        ///
        /// Mapping only `fermataAbove` left `fermataBelow` — engraved
        /// routinely under a bottom staff — falling through to
        /// `.unknown`, i.e. unlabeled ink inside a class the detector
        /// vocabulary already carries.
        @Test func classifiesTheWholeFermataFamilyButNotBreathMarks() {
            for cp in UInt32(0xE4C0) ... UInt32(0xE4CD) {
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .fermata)
            }
            // breathMarkComma / breathMarkTick / caesura — no class.
            for cp in UInt32(0xE4CE) ... UInt32(0xE4D7) {
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .unknown(cp))
            }
        }

        /// Repeats range: the two jump WORDS that SMuFL does draw as
        /// glyphs. `dalSegno` U+E045 and `daCapo` U+E046 sit immediately
        /// before the `segno` / `coda` pair this switch already knew.
        ///
        /// There is deliberately no `fine` and no `toCoda` here: SMuFL
        /// has no such glyph (only `coda` U+E048 and `codaSquare`
        /// U+E049), so those two detector classes are recovered from the
        /// TEXT stream instead — see `PDFImporter+Structure`'s marker
        /// text mapping.
        @Test func classifiesDalSegnoAndDaCapoGlyphs() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE043) == .repeatBarlineDots)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE045) == .dalSegno)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE046) == .daCapo)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE047) == .segno)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE048) == .coda)
        }

        /// The three coarse buckets. Whole SMuFL ranges map to one value
        /// each: the importer does not model dynamics, articulations or
        /// ornaments, and the point of classifying them is that their ink
        /// is accounted for rather than left to be mistaken for a
        /// neighbouring class.
        ///
        /// A blanket range claim is safe HERE and would not be in
        /// U+F400–F8FF: these are standard SMuFL ranges whose meanings
        /// are fixed by the specification, whereas the optional range is
        /// font-specific by definition (which is why the notehead
        /// aliases live in their own gated table).
        @Test func classifiesTheCoarseExpressionBuckets() {
            for cp in UInt32(0xE4A0) ... UInt32(0xE4BF) {
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .articulation)
            }
            for cp in UInt32(0xED40) ... UInt32(0xED4F) {
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .articulation)
            }
            for cp in UInt32(0xE520) ... UInt32(0xE54F) {
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .dynamic)
            }
            // commonOrnaments U+E560–E56F + otherBaroqueOrnaments U+E570–E58F.
            for cp in UInt32(0xE560) ... UInt32(0xE58F) {
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .ornament)
            }
        }

        /// The ranges must not run past their own boundaries. A bucket
        /// that swallows one codepoint too many is invisible: the label
        /// is present, plausible, and wrong — the failure mode this
        /// importer treats as the worst kind.
        @Test func coarseBucketsStopAtTheirRangeBoundaries() {
            for cp: UInt32 in [
                0xE49F,
                0xE51F,
                0xE550,
                0xE55F,
                0xE590,
                0xED3F,
                0xED50,
            ] {
                let semantic = PDFImporter.smuflSemantic(codepoint: cp)
                #expect(semantic != .articulation)
                #expect(semantic != .dynamic)
                #expect(semantic != .ornament)
            }
            // U+E4C0 is inside neither articulation nor the bucket that
            // follows it — it is the fermata the switch already had.
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4C0) == .fermata)
        }

        @Test func unknownCodepointReportsAsUnknown() {
            let semantic = PDFImporter.smuflSemantic(codepoint: 0xE999)
            if case let .unknown(cp) = semantic {
                #expect(cp == 0xE999)
            } else {
                Issue.record("expected .unknown")
            }
        }

        @Test func nonPUACodepointReportsAsUnknown() {
            let semantic = PDFImporter.smuflSemantic(codepoint: 0x41)
            if case .unknown = semantic {
                // ok
            } else {
                Issue.record("expected .unknown")
            }
        }

        @Test func pageStateAccumulatesClassifiedGlyphs() {
            let state = PDFPageState(pageIndex: 0)
            state.glyphs.append(ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: .zero, advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .noteheadBlack,
            ))
            #expect(state.glyphs.first?.semantic == .noteheadBlack)
        }
    }
#endif
