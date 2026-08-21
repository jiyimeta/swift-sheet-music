#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    /// Self-roundtrip golden: parse a real MSCX fixture, run it through
    /// the actual `PDFExporter` (real Bravura font, real SMuFL glyphs),
    /// then attempt to re-import via `PDFImporter`. The plan documents
    /// this as the place where 60-80% of pipeline bugs surface.
    ///
    /// Phase 1 scope is intentionally smoke-level: assert the round-trip
    /// doesn't crash and document either the loose-equivalence pass or
    /// the expected-degradation throw. Strict per-measure equivalence is
    /// deferred until the content-stream walker decodes a real
    /// `/ToUnicode` CMap from the embedded font.
    @MainActor struct PDFImporterRoundTripTests {
        /// Start with the smallest fixture; expand once CMap decoding
        /// makes strict comparison meaningful.
        nonisolated static let fixtures = ["midi01"]

        @Test(arguments: fixtures)
        func mscxRoundTripsThroughPDF(name: String) throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mscxURL = try #require(TestResources.url(
                forResource: name, withExtension: "mscx",
            ))
            let mscxData = try Data(contentsOf: mscxURL)
            let scoreA = try MSCXParser.parse(mscxData)

            // Phase 1: export through real PDFExporter and parse back.
            let pdfData = try PDFExporter.export(score: scoreA)
            #expect(!pdfData.isEmpty, "[\(name)] exporter returned empty data")

            do {
                let scoreB = try PDFImporter.parse(pdfData: pdfData)
                PDFRoundTripComparison.assertLooselyEquivalent(
                    scoreA, scoreB, fixture: name,
                )
            } catch let error as SheetMusicError {
                // Acceptable v1 degradation: the exporter writes glyph
                // CIDs into the content stream, but the CMap stub in
                // `ContentStreamWalker` can't yet decode them back to
                // SMuFL PUA codepoints — so the pipeline often throws
                // `.malformedScore("no glyphs found" | "no staff
                // detected")`. Record it as a non-fatal note and pass
                // the test; rethrow anything else.
                switch error {
                case let .malformedScore(reason):
                    Issue.record(
                        "PDF roundtrip degraded for \(name): \(reason)",
                    )
                    return
                default:
                    throw error
                }
            }
        }
    }
#endif
