#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// End-to-end wiring check for `PDFImportOptions.enableShapeMatching`.
    ///
    /// `GlyphClassifierTests` constructs `GlyphClassifier` directly, so it
    /// never exercises the path that actually matters in production:
    ///
    /// ```
    /// PDFImportOptions -> parse / parseWithGeometry -> walkDocument
    ///   -> ContentStreamWalker -> state.classifiers -> GlyphClassifier
    /// ```
    ///
    /// A regression anywhere in that threading — e.g.
    /// `PDFImporter+ContentStream.swift` hardcoding
    /// `enableShapeMatching: true`, or `parse`/`parseWithGeometry` silently
    /// dropping the option instead of forwarding it — would pass every test
    /// in `GlyphClassifierTests` untouched. This file goes through the real
    /// public entry point instead.
    ///
    /// It also exists because `measureCorpusDiff` (the spike ground-truth
    /// harness) does NOT assert anything — it only prints six `[SUMMARY]`
    /// lines for a human to diff by eye each round. There is no other
    /// automated gate that would catch a broken flag; this test is it.
    @MainActor struct PDFImporterShapeMatchingGateTests {
        /// `PDFImportOptions.diagnostics` is `@Sendable`, so a captured `var`
        /// array can't be mutated from inside the closure under strict
        /// concurrency. Same reference-typed sink shape as
        /// `PDFImporterDiagnosticsTests.DiagnosticSink` — the `NSLock` keeps
        /// mutation race-free even though this test is single-threaded.
        private final class DiagnosticSink: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [PDFImportDiagnostic] = []
            func append(_ d: PDFImportDiagnostic) {
                lock.lock(); defer { lock.unlock() }
                items.append(d)
            }

            var snapshot: [PDFImportDiagnostic] {
                lock.lock(); defer { lock.unlock() }
                return items
            }
        }

        private static var corpusPath: String {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/pdf_test/ギブス.pdf").path
        }

        /// With `enableShapeMatching` left at its default (false), parsing a
        /// real MuseScore PDF through `PDFImporter.parse(pdfData:options:)`
        /// must leave a healthy population of `.unknown`-SMuFL-codepoint
        /// diagnostics (the lyric/text glyphs Tier 1 correctly can't
        /// classify) AND must still attach real lyrics to chords.
        ///
        /// Both signals FLIP when Tier 4 is turned on — verified by hand
        /// (not committed here; see task-12-report.md for the exact
        /// numbers): with `enableShapeMatching: true` substituted into this
        /// same call, the unknown-diagnostic count drops from a healthy
        /// population to exactly 0 (Round 1's ギブス.pdf finding: 0 of 4254
        /// glyphs left `.unknown`), Tier 4 misclassifies the CJK lyric
        /// font's outlines as music glyphs, the `TextGlyph` runs
        /// `buildScore` would otherwise turn into `Lyric`s are swallowed,
        /// and this test's assertions fail — proving both signals actually
        /// depend on the flag rather than being coincidentally always true.
        ///
        /// Skips gracefully (returns) when the developer's local PDF corpus
        /// isn't present, so CI — which has no copy of this copyrighted
        /// fixture — stays green; the assertions bite whenever the file IS
        /// present, including every local run in this worktree.
        @Test func defaultOptionsLeaveUnknownDiagnosticsAndLyricsIntact() throws {
            let path = Self.corpusPath
            guard FileManager.default.fileExists(atPath: path) else { return }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))

            let sink = DiagnosticSink()
            var options = PDFImportOptions()
            options.diagnostics = { sink.append($0) }
            // Deliberately NOT setting `enableShapeMatching` — the whole
            // point is to prove the DEFAULT, reached through the real
            // public entry point, behaves as documented.
            let score = try PDFImporter.parse(pdfData: data, options: options)

            let unknownGlyphDiagnostics = sink.snapshot.filter {
                $0.message.hasPrefix("Unknown SMuFL codepoint")
            }
            #expect(!unknownGlyphDiagnostics.isEmpty)

            let lyricCount = score.parts
                .flatMap(\.staves)
                .flatMap(\.measures)
                .flatMap(\.voices)
                .flatMap(\.elements)
                .compactMap { element -> Chord? in
                    if case let .chord(chord) = element { return chord }
                    return nil
                }
                .reduce(0) { $0 + $1.lyrics.count }
            #expect(lyricCount > 0)
        }
    }
#endif
