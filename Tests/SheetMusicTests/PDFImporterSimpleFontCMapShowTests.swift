#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// Unit tests for a SIMPLE font that also carries a `/ToUnicode` CMap —
    /// the shape MuseScore 4 emits when it embeds Leland / LelandText /
    /// Bravura as Type 1C (single-byte codes, a `/Differences` encoding AND
    /// a ToUnicode CMap), rather than as CID TrueType Identity-H.
    ///
    /// THE REGRESSION GUARD. `emitShow` used to decide the code width from
    /// the mere PRESENCE of a non-empty CMap and read two bytes per code.
    /// Those are not the same question: a simple font's codes are one byte
    /// each, so every synthesised 2-byte CID missed the CMap and was
    /// discarded. A real MuseScore 4 export parsed to 6 parts and 91
    /// measures with ZERO notes, zero rests and zero diagnostics.
    ///
    /// The font's CMap is not discarded for a simple font — it is exactly
    /// what maps Leland's single-byte codes to the SMuFL PUA codepoints the
    /// classifier recognizes.
    struct PDFImporterSimpleFontCMapShowTests {
        private static let noteheadPUA: Unicode.Scalar = "\u{E0A4}"
        private static let clefPUA: Unicode.Scalar = "\u{E050}"

        /// A font registered WITHOUT being named a Type0 font — i.e. a simple
        /// font, which is what `/Subtype /Type1` means.
        private func pageState() -> PDFPageState {
            let state = PDFPageState(pageIndex: 0)
            state.fontSize = 30
            state.fontCMaps = ["F1": PDFImporter.ToUnicodeCMap(table: [
                0x20: [Self.noteheadPUA],
                0x21: [Self.clefPUA],
                0x41: ["A"],
            ])]
            state.opSetFont(name: "F1", size: 30)
            return state
        }

        @Test func aSingleByteCodeClassifiesThroughTheFontsOwnCMap() {
            let state = pageState()
            emitShow([0x20], state: state)
            #expect(state.glyphs.count == 1)
            #expect(state.glyphs.first?.semantic == .noteheadBlack)
        }

        /// Two one-byte codes are two glyphs — not one paired CID that the
        /// CMap cannot answer.
        @Test func twoSingleByteCodesAreTwoGlyphs() {
            let state = pageState()
            emitShow([0x20, 0x21], state: state)
            #expect(state.glyphs.count == 2)
            #expect(state.glyphs.first?.semantic == .noteheadBlack)
            #expect(state.glyphs.last?.semantic == .clefG)
        }

        /// A non-PUA scalar still routes to the text stream, decoded through
        /// the same CMap.
        @Test func aNonMusicCodeBecomesText() {
            let state = pageState()
            emitShow([0x41], state: state)
            #expect(state.glyphs.isEmpty)
            #expect(state.texts.count == 1)
            #expect(state.texts.first?.text == "A")
        }

        // MARK: - The dropped-code path reports

        /// A code the CMap cannot map is still dropped — but never silently.
        /// The bare `continue` that used to swallow it is why the wrong code
        /// width could take a whole document's music with it and emit zero
        /// diagnostics.
        @Test func anUnmappedCodeIsTalliedForTheCaller() {
            let state = pageState()
            emitShow([0x7F], state: state)
            #expect(state.glyphs.isEmpty)
            #expect(state.undecodedCodes.count == 1)
            #expect(state.undecodedCodes.first?.fontName == "F1")
            #expect(state.undecodedCodes.first?.firstCode == 0x7F)
            #expect(state.undecodedCodes.first?.count == 1)
        }

        /// Tallied per font, not per glyph: a document read at the wrong code
        /// width misses on every code, and one diagnostic each would bury the
        /// caller.
        @Test func repeatedMissesShareOneTally() {
            let state = pageState()
            emitShow([0x7F, 0x7E, 0x7D], state: state)
            #expect(state.undecodedCodes.count == 1)
            #expect(state.undecodedCodes.first?.count == 3)
        }

        /// And the tally reaches the caller's diagnostics callback.
        @Test func theTallyIsReportedThroughTheDiagnosticsCallback() {
            let box = DiagnosticBox()
            var options = PDFImportOptions()
            options.diagnostics = { box.append($0) }
            PDFImporter.emitUndecodedCodeDiagnostics([
                UndecodedCodeTally(
                    pageIndex: 2, fontName: "F7", firstCode: 0x2021, count: 91,
                ),
            ], options: options)
            #expect(box.messages.count == 1)
            #expect(box.messages.first?.contains("91") == true)
        }

        /// `PDFImportOptions.diagnostics` is `@Sendable`, so the collector it
        /// writes into has to be a reference type the closure can capture.
        private final class DiagnosticBox: @unchecked Sendable {
            private(set) var messages: [String] = []
            func append(_ diagnostic: PDFImportDiagnostic) {
                messages.append(diagnostic.message)
            }
        }
    }
#endif
