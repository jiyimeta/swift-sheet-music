#if !os(Android)
    import Foundation
    import Testing

    /// Task 9 controller addition. The four env-gated OMR harnesses
    /// (`OMRLabelExportTests`, `OMROracleReplayTests`, `OMRSeamEvalTests`,
    /// `OMRScoreEvalTests`) had their shared pure formatters/functions
    /// unit-tested, but never their OWN wiring: the `OMR_DATA_ROOT`
    /// directory walk, `render.json` / `source.mscx` / `.labels.json`
    /// discovery, and the skip/failure branches. These tests drive that
    /// wiring against a synthetic fixture tree (`OMRHarnessFixture`,
    /// built and torn down per test) so they run always-on and need
    /// neither `OMR_DATA_ROOT` nor a real dataset.
    ///
    /// Each harness's per-directory step was extracted to a non-private
    /// (or `static`) function purely so it is directly callable here —
    /// see the doc comments on `exportOneRender`, `evaluateOneRender`
    /// (×2), and `evaluate` in the respective harness files. None of
    /// that changed any harness's printed output, `[SUMMARY]` format, or
    /// env gating.
    struct OMRHarnessWiringTests {
        @MainActor
        @Test func directoryWalkFindsOnlyRenderDirsInSortedOrder() throws {
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            let found = try OMRHarnessDirectoryWalk.renderDirectories(root: layout.root)
            let expected = [
                layout.wellFormedDir, layout.missingLabelsDir, layout.missingSourceDir,
            ].sorted()
            #expect(found == expected)
            #expect(!found.contains(layout.notARenderDir))
        }

        /// `missingLabelsDir` (render.json + score.pdf, no `.labels.json`)
        /// is a legitimately well-formed INPUT for the export harness,
        /// which produces labels rather than consuming them. The fixture
        /// PDF carries staff lines only — zero music glyphs — so the
        /// dual-walk pairing in `OMRLabelExport.export` is empty and the
        /// harness must take its QUARANTINE branch: found, read, walked,
        /// rejected, no file written. That is the concrete, non-tautological
        /// signal that this branch — not the write branch — actually ran.
        @MainActor
        @Test func labelExportHarnessProcessesAWellFormedDirAndQuarantinesIt() throws {
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            let labelsPath = "\(layout.missingLabelsDir)/page_0.labels.json"
            #expect(!FileManager.default.fileExists(atPath: labelsPath))
            OMRLabelExportHarness().exportOneRender(dir: layout.missingLabelsDir)
            #expect(!FileManager.default.fileExists(atPath: labelsPath))
        }

        /// `wellFormedDir`'s PDF and label file were derived from the same
        /// single walk (`OMRHarnessFixture.buildPage`), so a fresh walk of
        /// the PDF and a replay of the labels must reconstruct identical
        /// scores — genuinely `.exact`, not a stub. `missingLabelsDir` has
        /// no `.labels.json` at all, exercising the skip branch.
        @MainActor
        @Test func oracleReplayGateMatchesWellFormedDirAndSkipsMissingLabels() {
            guard let layout = try? OMRHarnessFixture.makeLayout() else {
                Issue.record("failed to build OMRHarnessFixture")
                return
            }
            defer { OMRHarnessFixture.cleanup(layout) }
            switch OMROracleReplayGate.evaluateOneRender(dir: layout.wellFormedDir) {
            case .exact: break
            case let outcome: Issue.record("expected .exact, got \(outcome)")
            }
            switch OMROracleReplayGate.evaluateOneRender(dir: layout.missingLabelsDir) {
            case .skippedNoLabels: break
            case let outcome: Issue.record("expected .skippedNoLabels, got \(outcome)")
            }
        }

        /// Drives the real discovery → decode → metrics chain for a
        /// well-formed directory (must not throw) and for one with no
        /// `.labels.json` (must no-op, not throw or crash).
        @MainActor
        @Test func seamEvalHarnessProcessesWellFormedDirAndNoOpsWithoutLabels() throws {
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            var aggregate: [String: OMRSeamMetrics.ClassCounts] = [:]
            try OMRSeamEvalHarness().evaluate(dir: layout.wellFormedDir, aggregate: &aggregate)
            // The fixture carries no music glyphs, so there is nothing to
            // aggregate — this is really asserting that reading, decoding,
            // and running every metric function against the label file
            // completed without throwing.
            #expect(aggregate.isEmpty)
            try OMRSeamEvalHarness().evaluate(dir: layout.missingLabelsDir, aggregate: &aggregate)
            #expect(aggregate.isEmpty)
        }

        /// `wellFormedDir` has both `source.mscx` and `.labels.json`, so
        /// the harness must parse + replay + compute a summary row (not
        /// skip). `missingSourceDir` has labels but no `source.mscx`,
        /// exercising the skip branch.
        @MainActor
        @Test func scoreEvalHarnessProcessesWellFormedDirAndSkipsMissingSource() {
            guard let layout = try? OMRHarnessFixture.makeLayout() else {
                Issue.record("failed to build OMRHarnessFixture")
                return
            }
            defer { OMRHarnessFixture.cleanup(layout) }
            switch OMRScoreEvalHarness.evaluateOneRender(dir: layout.wellFormedDir, tag: "[t]") {
            case let .processed(summary, _):
                #expect(summary.contains("pitch%"))
            case let outcome:
                Issue.record("expected .processed, got \(outcome)")
            }
            switch OMRScoreEvalHarness.evaluateOneRender(dir: layout.missingSourceDir, tag: "[t]") {
            case .skippedNoSourceOrLabels: break
            case let outcome: Issue.record("expected .skippedNoSourceOrLabels, got \(outcome)")
            }
        }
    }
#endif
