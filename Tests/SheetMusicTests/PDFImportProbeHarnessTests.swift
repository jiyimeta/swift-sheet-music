#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// One-shot EVIDENCE harness for the "6 parts / 91 measures / 0 notes /
    /// 0 rests / 0 diagnostics" bug on real MuseScore 4 vector PDFs
    /// (2026-08-30/31 investigation,
    /// `.superpowers/sdd/2026-08-30-omr-raster-integration/pdf-probe-report.md`).
    /// Calls `PDFImporter.walkDocument` directly — the internal step between
    /// the content-stream text-show operator and the classified-glyph
    /// output that `PDFImporter.parse` itself calls — and PRINTS where every
    /// glyph/text/path/curve the walk produced actually went. This is a
    /// reporting tool, not a correctness test: it makes no `#expect` calls,
    /// on purpose, so it never goes stale as a false-green gate.
    ///
    /// No-op unless `SM_PDF_PROBE` is set. Its VALUE is the PDF path itself
    /// (tilde-expanded), mirroring `Sources/RenderPreviews/AdHocPDFImport
    /// .swift`'s `SM_PDF` convention rather than the `..._EVAL=1` + separate
    /// `..._ROOT` two-variable pattern used by the corpus-sweep harnesses —
    /// there is exactly one file to point at here.
    ///
    ///     SM_PDF_PROBE=~/path/to/file.pdf \
    ///         swift test --filter PDFImportProbeHarness
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["SM_PDF_PROBE"] != nil))
    struct PDFImportProbeHarness {
        @Test func walkDocumentReportsGlyphAndTextRouting() throws {
            guard let rawPath = ProcessInfo.processInfo.environment["SM_PDF_PROBE"] else {
                Issue.record("SM_PDF_PROBE unset")
                return
            }
            let path = (rawPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let document = try PDFImporter.openDocument(data)
            let walk = try PDFImporter.walkDocument(document)
            let content = walk.content

            // 1. Totals from the walk.
            print(
                "[pdf-probe][totals] glyphs=\(content.glyphs.count) "
                    + "texts=\(content.texts.count) paths=\(content.paths.count) "
                    + "curves=\(content.curves.count)",
            )

            // 2. Glyph breakdown by SMuFLSemantic case.
            Self.printGlyphBreakdown(content.glyphs)

            // 3. Text breakdown by fontName — the load-bearing check: if the
            // music fonts (Leland / LelandText / Bravura) show up here, the
            // music glyphs are being routed into the text stream instead of
            // the glyph stream.
            Self.printTextBreakdown(content.texts)

            // 4. Per-font glyph counts. `ClassifiedGlyph` / `GlyphGeometry`
            // (Sources/SheetMusicPDF/Import/Internal.swift) carry no
            // fontName field — the source font is not retained past
            // classification — so this cannot be reported without a
            // production change. Stated rather than invented.
            print(
                "[pdf-probe][glyph-font] ClassifiedGlyph/GlyphGeometry retain no "
                    + "fontName field; per-font glyph counts are NOT AVAILABLE "
                    + "without changing production code",
            )
        }

        /// Item 2: how many `ClassifiedGlyph`s carry each `SMuFLSemantic`
        /// case (associated-value cases collapsed to their case name);
        /// `.unknown` codepoints are additionally broken out.
        private static func printGlyphBreakdown(_ glyphs: [ClassifiedGlyph]) {
            var glyphCaseCounts: [String: Int] = [:]
            var unknownCodepointCounts: [UInt32: Int] = [:]
            for glyph in glyphs {
                let name = Self.caseName(glyph.semantic)
                glyphCaseCounts[name, default: 0] += 1
                if case let .unknown(codepoint) = glyph.semantic {
                    unknownCodepointCounts[codepoint, default: 0] += 1
                }
            }
            if glyphCaseCounts.isEmpty {
                print("[pdf-probe][glyphs] none")
            } else {
                for name in glyphCaseCounts.keys.sorted() {
                    print("[pdf-probe][glyphs] semantic=\(name) count=\(glyphCaseCounts[name] ?? 0)")
                }
            }
            for codepoint in unknownCodepointCounts.keys.sorted() {
                let hex = String(codepoint, radix: 16, uppercase: true)
                print("[pdf-probe][glyphs][unknown] codepoint=U+\(hex) count=\(unknownCodepointCounts[codepoint] ?? 0)")
            }
        }

        /// Item 3: for each distinct `fontName` in `walked.texts`, the run
        /// count and the first three decoded strings, plus a check for the
        /// music fonts specifically.
        private static func printTextBreakdown(_ texts: [TextGlyph]) {
            var textsByFont: [String: [TextGlyph]] = [:]
            for text in texts {
                textsByFont[text.fontName, default: []].append(text)
            }
            if textsByFont.isEmpty {
                print("[pdf-probe][text] none")
            }
            for font in textsByFont.keys.sorted() {
                let runs = textsByFont[font] ?? []
                let samples = runs.prefix(3).map { Self.escapeNonPrinting($0.text) }
                print("[pdf-probe][text] font=\(font) runs=\(runs.count) samples=\(samples)")
            }
            let musicFontNames = ["Leland", "LelandText", "Bravura"]
            let musicFontHits = textsByFont.filter { fontName, _ in
                musicFontNames.contains { fontName.contains($0) }
            }
            if musicFontHits.isEmpty {
                print("[pdf-probe][music-fonts-in-text] NONE of Leland/LelandText/Bravura appear in walked.texts")
            } else {
                for (font, runs) in musicFontHits.sorted(by: { $0.key < $1.key }) {
                    print("[pdf-probe][music-fonts-in-text] font=\(font) runs=\(runs.count)")
                }
            }
        }

        private static func caseName(_ semantic: SMuFLSemantic) -> String {
            switch semantic {
            case .brace: "brace"
            case .noteheadBlack: "noteheadBlack"
            case .noteheadHalf: "noteheadHalf"
            case .noteheadWhole: "noteheadWhole"
            case .noteheadDoubleWhole: "noteheadDoubleWhole"
            case .noteheadXBlack: "noteheadXBlack"
            case .noteheadXHalf: "noteheadXHalf"
            case .noteheadXWhole: "noteheadXWhole"
            case .stem: "stem"
            case .flag8thUp: "flag8thUp"
            case .flag8thDown: "flag8thDown"
            case .flag16thUp: "flag16thUp"
            case .flag16thDown: "flag16thDown"
            case .flag32ndUp: "flag32ndUp"
            case .flag32ndDown: "flag32ndDown"
            case .flag64thUp: "flag64thUp"
            case .flag64thDown: "flag64thDown"
            case .augmentationDot: "augmentationDot"
            case .rest: "rest"
            case .clefG: "clefG"
            case .clefF: "clefF"
            case .clefC: "clefC"
            case .clefPercussion: "clefPercussion"
            case .clefG8vb: "clefG8vb"
            case .clefG8va: "clefG8va"
            case .clefG15ma: "clefG15ma"
            case .clefG15mb: "clefG15mb"
            case .clefF8va: "clefF8va"
            case .clefF8vb: "clefF8vb"
            case .clefF15ma: "clefF15ma"
            case .clefF15mb: "clefF15mb"
            case .accidentalSharp: "accidentalSharp"
            case .accidentalFlat: "accidentalFlat"
            case .accidentalNatural: "accidentalNatural"
            case .accidentalDoubleSharp: "accidentalDoubleSharp"
            case .accidentalDoubleFlat: "accidentalDoubleFlat"
            case .timeSignatureDigit: "timeSignatureDigit"
            case .timeSignatureCommon: "timeSignatureCommon"
            case .timeSignatureCutTime: "timeSignatureCutTime"
            case .staff5Lines: "staff5Lines"
            case .repeatBarlineDots: "repeatBarlineDots"
            case .segno: "segno"
            case .coda: "coda"
            case .dalSegno: "dalSegno"
            case .daCapo: "daCapo"
            case .fine: "fine"
            case .toCoda: "toCoda"
            case .fermata: "fermata"
            case .dynamic: "dynamic"
            case .articulation: "articulation"
            case .ornament: "ornament"
            case .unknown: "unknown"
            }
        }

        /// Escapes every scalar outside printable ASCII as `\u{XXXX}`, so a
        /// music-font codepoint (or a stray control character) in a decoded
        /// text run shows up legibly in the log instead of as an invisible
        /// box or a literal newline/tab.
        private static func escapeNonPrinting(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                if scalar.value >= 0x20, scalar.value < 0x7F {
                    out.unicodeScalars.append(scalar)
                } else {
                    out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                }
            }
            return out
        }
    }
#endif
