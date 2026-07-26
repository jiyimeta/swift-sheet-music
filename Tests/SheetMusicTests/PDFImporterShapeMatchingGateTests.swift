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

        /// With `enableShapeMatching` turned ON, the per-font music-font gate
        /// (`GlyphClassifier.isLikelyMusicFont`, Task 14) must keep lyrics
        /// intact: Tier 4 should only ever answer for the actual music-
        /// notation font's glyphs (Leland here), never for the CJK lyric
        /// font's (Hiragino) or the Latin text font's (Edwin) outlines —
        /// even though the global flag no longer distinguishes them.
        ///
        /// Task 12 measured what happens WITHOUT a gate: at the placeholder
        /// threshold, lyric recall collapsed from 92% to 0% and 0 of 4254
        /// glyphs on this PDF were left `.unknown`. This test does not
        /// assert anything about Tier 4's classification ACCURACY — that is
        /// `tier4Ablation`'s job — only that non-music fonts stay excluded
        /// once the global switch is flipped on. Measured with the gate on
        /// (Task 14): 779 lyrics attach, identical to the default-off parse
        /// of this same PDF — the gate loses nothing on the real corpus.
        @Test func shapeMatchingWithGateDoesNotCollapseLyrics() throws {
            let path = Self.corpusPath
            guard FileManager.default.fileExists(atPath: path) else { return }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))

            var options = PDFImportOptions()
            options.enableShapeMatching = true
            let score = try PDFImporter.parse(pdfData: data, options: options)

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
            // A healthy population, not merely > 0 — a handful surviving by
            // accident wouldn't distinguish "the gate works" from "the gate
            // is a no-op that happens to miss a few glyphs". The DEFAULT
            // (enableShapeMatching: false) parse of this same PDF attaches
            // 779 lyric syllables; requiring most of that population to
            // survive with the gate ON is a real assertion.
            #expect(lyricCount > 200)
        }

        /// Proves `shapeMatchingWithGateDoesNotCollapseLyrics` is a genuine
        /// regression catch, not a tautology: with the gate forced open
        /// (`musicFontGateFraction = 0` accepts every font regardless of its
        /// sampled distances) AND `shapeAcceptanceThreshold` restored to the
        /// pre-Task-14 placeholder (0.45), Tier 4 again matches the CJK
        /// lyric font's outlines to Bravura exemplars and lyric count
        /// collapses to exactly 0 — byte-for-byte reproducing Task 12's
        /// original finding on this PDF.
        @Test func noGateAtPlaceholderThresholdReproducesTask12Collapse() throws {
            let path = Self.corpusPath
            guard FileManager.default.fileExists(atPath: path) else { return }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))

            let savedFraction = GlyphClassifier.musicFontGateFraction
            let savedBound = GlyphClassifier.musicFontGateBound
            let savedAccept = GlyphClassifier.shapeAcceptanceThreshold
            GlyphClassifier.musicFontGateFraction = 0
            GlyphClassifier.musicFontGateBound = 1.0
            GlyphClassifier.shapeAcceptanceThreshold = 0.45
            defer {
                GlyphClassifier.musicFontGateFraction = savedFraction
                GlyphClassifier.musicFontGateBound = savedBound
                GlyphClassifier.shapeAcceptanceThreshold = savedAccept
            }

            var options = PDFImportOptions()
            options.enableShapeMatching = true
            let score = try PDFImporter.parse(pdfData: data, options: options)

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
            #expect(lyricCount == 0)
        }
    }
#endif
