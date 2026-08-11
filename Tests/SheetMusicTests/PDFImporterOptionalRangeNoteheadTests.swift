#if !os(Android)
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    /// Tier 1b — noteheads drawn from SMuFL's font-specific optional-glyph
    /// range (U+F400–U+F8FF).
    ///
    /// MEASURED: MuseScore draws noteheads for Bravura and Petaluma at
    /// U+F4BA / U+F4BC / U+F4BD / U+F4BE instead of the standard
    /// U+E0A0 / U+E0A2 / U+E0A3 / U+E0A4, while every other glyph class
    /// stays on the standard codepoints. Before this tier existed, such a
    /// PDF imported with ZERO notes (notesA=84 notesB=0 on a generated
    /// fixture whose Leland export recovered all 84).
    ///
    /// Reproduced on 6 user-authored scores re-engraved in Petaluma — five
    /// of them exported by MuseScore **3** — so this is font-specific
    /// behavior, not a MuseScore-4 quirk.
    struct PDFImporterOptionalRangeNoteheadTests {
        // MARK: - The alias table

        @Test func aliasesResolveToTheStandardNoteheadSemantics() {
            #expect(
                PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF4BA)
                    == .noteheadDoubleWhole,
            )
            #expect(
                PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF4BC)
                    == .noteheadWhole,
            )
            #expect(
                PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF4BD)
                    == .noteheadHalf,
            )
            #expect(
                PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF4BE)
                    == .noteheadBlack,
            )
        }

        /// The table must not claim the whole optional range. U+F400 is the
        /// ONLY optional-range codepoint that occurs anywhere in the 132-PDF
        /// real corpus (6 occurrences), so a table that answered for it would
        /// change that corpus's output — the thing gate P0-G4 forbids.
        @Test func unlistedOptionalCodepointsAreNotClaimed() {
            #expect(PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF400) == nil)
            #expect(PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF4BB) == nil)
            #expect(PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xF8FF) == nil)
        }

        /// Standard-range codepoints are Tier 1's business, not this table's.
        @Test func standardRangeCodepointsAreNotClaimed() {
            #expect(PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xE0A4) == nil)
            #expect(PDFImporter.smuflOptionalRangeSemantic(codepoint: 0xE050) == nil)
        }

        /// Semantics are derived from `smuflSemantic`, never restated, so
        /// the two tables cannot drift apart.
        @Test func everyAliasPointsAtACodepointTier1Recognizes() {
            for (optional, standard) in PDFImporter.smuflOptionalNoteheadAliases {
                let viaTier1 = PDFImporter.smuflSemantic(codepoint: standard)
                let names = "U+\(String(optional, radix: 16, uppercase: true)) -> "
                    + "U+\(String(standard, radix: 16, uppercase: true))"
                if case .unknown = viaTier1 {
                    Issue.record("alias \(names): Tier 1 does not know the target")
                }
                #expect(
                    PDFImporter.smuflOptionalRangeSemantic(codepoint: optional) == viaTier1,
                    "\(names)",
                )
            }
        }

        // MARK: - The per-font evidence gate

        /// A font that also maps recognized STANDARD-range codepoints is
        /// speaking SMuFL, so its optional range may be read as the
        /// Steinberg layout. Measured: Bravura and Petaluma exports map 39
        /// distinct standard-range codepoints alongside the four aliases.
        @Test func aCMapWithStandardSMuFLCodepointsCarriesEvidence() {
            let cmap = PDFImporter.ToUnicodeCMap(table: [
                1: ["\u{E050}"], // clefG
                2: ["\u{F4BE}"], // the optional-range notehead
            ])
            #expect(cmap.mapsRecognizedStandardSMuFLCodepoints)
        }

        /// An icon font squatting on the private use area maps nothing Tier 1
        /// recognizes, so it never reaches the alias table and can never have
        /// a notehead invented for it.
        @Test func aCMapWithOnlyOptionalRangeCodepointsCarriesNoEvidence() {
            let cmap = PDFImporter.ToUnicodeCMap(table: [
                1: ["\u{F4BE}"],
                2: ["\u{F4BD}"],
            ])
            #expect(!cmap.mapsRecognizedStandardSMuFLCodepoints)
        }

        @Test func anOrdinaryTextCMapCarriesNoEvidence() {
            let cmap = PDFImporter.ToUnicodeCMap(table: [1: ["A"], 2: ["b"]])
            #expect(!cmap.mapsRecognizedStandardSMuFLCodepoints)
        }

        /// A PUA codepoint in the standard range that Tier 1 does NOT
        /// recognize is not evidence either — the predicate asks what the
        /// font demonstrably speaks, not merely where it draws.
        @Test func unrecognizedStandardRangePUAIsNotEvidence() {
            let cmap = PDFImporter.ToUnicodeCMap(table: [1: ["\u{E999}"]])
            #expect(!cmap.mapsRecognizedStandardSMuFLCodepoints)
        }

        // MARK: - The show path

        /// Identity-H is 2 bytes per CID.
        private func cid(_ value: UInt16) -> [UInt8] {
            [UInt8(value >> 8), UInt8(value & 0xFF)]
        }

        private func pageState(
            table: [UInt32: [Unicode.Scalar]], disableTier1: Bool = false,
        ) -> PDFPageState {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = 30
            state.disableSMuFLCodepointTier = disableTier1
            state.fontCMaps = ["F1": PDFImporter.ToUnicodeCMap(table: table)]
            state.opSetFont(name: "F1", size: 30)
            return state
        }

        /// THE REGRESSION GUARD: this is the shape that imported zero notes.
        @Test func anOptionalRangeNoteheadClassifiesOnTheShowPath() {
            let state = pageState(table: [1: ["\u{E050}"], 2: ["\u{F4BE}"]])
            emitShow(cid(2), state: state)
            #expect(state.glyphs.count == 1)
            #expect(state.glyphs.first?.semantic == .noteheadBlack)
        }

        /// Without standard-range evidence the same codepoint stays unknown,
        /// so it is still recorded (never dropped, never guessed).
        @Test func withoutEvidenceTheSameCodepointStaysUnknown() {
            let state = pageState(table: [1: ["\u{F4BD}"], 2: ["\u{F4BE}"]])
            emitShow(cid(2), state: state)
            #expect(state.glyphs.count == 1)
            #expect(state.glyphs.first?.semantic == .unknown(0xF4BE))
        }

        /// The Tier-4 ablation spike measures shape matching against Tier 1's
        /// known-correct answer by suppressing Tier 1. Tier 1b is part of the
        /// codepoint tier, so it must be suppressed with it or the ablation
        /// silently measures something else.
        @Test func disablingTheCodepointTierAlsoDisablesTheAliasTable() {
            let state = pageState(
                table: [1: ["\u{E050}"], 2: ["\u{F4BE}"]], disableTier1: true,
            )
            emitShow(cid(2), state: state)
            #expect(state.glyphs.first?.semantic == .unknown(0xF4BE))
        }

        // MARK: - Derivation: the table is shape identity, not four constants

        /// Resolve one codepoint's outline in the bundled reference font.
        @available(macOS 15.0, *)
        private func descriptor(_ codepoint: UInt32, font: CTFont) -> ShapeDescriptor? {
            guard let scalar = Unicode.Scalar(codepoint) else { return nil }
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count),
                  let gid = glyphs.first, gid != 0,
                  let path = CTFontCreatePathForGlyph(font, gid, nil), !path.isEmpty
            else { return nil }
            return makeDescriptor(path: path)
        }

        /// THE TABLE'S JUSTIFICATION. Each optional-range glyph must be
        /// nearest — with a margin over the runner-up — to the exemplar of
        /// the very semantic the table claims for it. That makes the table a
        /// derived fact about the reference font rather than four numbers
        /// someone typed, and it fails loudly if a future Bravura moves the
        /// block.
        ///
        /// Measured shapes: U+E0A4 is bbox 295×250 advance 295 at gid 158,
        /// U+F4BE is 329×280 advance 329 at gid 2992 — the same outline
        /// about 12% larger, six CGPath elements each.
        @Test func eachAliasIsNearestToTheExemplarItClaims() throws {
            guard #available(macOS 15.0, *), BravuraFont.register else { return }
            let font = CTFontCreateWithName(
                BravuraFont.familyName as CFString, 1000, nil,
            )
            try #require(CTFontCopyFamilyName(font) as String == "Bravura")

            for (optional, standard) in PDFImporter.smuflOptionalNoteheadAliases {
                guard let probe = descriptor(optional, font: font) else {
                    Issue.record("no outline for U+\(String(optional, radix: 16))")
                    continue
                }
                let claimed = PDFImporter.smuflSemantic(codepoint: standard)
                var ranked = BravuraExemplars.all
                    .map { (semantic: $0.semantic, d: probe.distance(to: $0.descriptor)) }
                    .sorted { $0.d < $1.d }
                // Collapse the exemplars that share the claimed semantic, so
                // a duplicate entry cannot masquerade as the runner-up.
                let best = try #require(ranked.first)
                ranked.removeAll { $0.semantic == best.semantic }
                let runnerUp = try #require(ranked.first)
                let report = "U+\(String(optional, radix: 16, uppercase: true)): "
                    + "nearest=\(best.semantic) \(best.d), "
                    + "runnerUp=\(runnerUp.semantic) \(runnerUp.d)"
                #expect(best.semantic == claimed, "\(report)")
                #expect(runnerUp.d > best.d * 1.25, "margin too thin — \(report)")
            }
        }

        // MARK: - U+E0A0, the plain double whole

        /// U+E0A1 is `noteheadDoubleWholeSquare`; the plain double whole is
        /// U+E0A0 and was unmapped, so every breve was dropped from every
        /// import in every font. This package's own
        /// `SMuFLCodepoints+Noteheads.swift:159-160` has the pair right.
        @Test func plainDoubleWholeCodepointIsRecognized() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A0) == .noteheadDoubleWhole)
        }

        /// The square variant keeps its mapping: it draws a double whole too,
        /// and this importer's Note model carries no head shape.
        @Test func squareDoubleWholeStillMapsToTheSameSemantic() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A1) == .noteheadDoubleWhole)
        }

        /// `BravuraExemplars` is built from the codepoints Tier 1 classifies,
        /// so the exemplar set must not keep inheriting the gap.
        @Test func exemplarCodepointsIncludeThePlainDoubleWhole() {
            #expect(BravuraExemplars.codepoints.contains(0xE0A0))
        }
    }
#endif
