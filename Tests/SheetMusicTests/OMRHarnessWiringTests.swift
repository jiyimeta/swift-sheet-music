#if !os(Android) && !os(WASI)
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
    /// Each harness's per-directory step was extracted to a `static`
    /// `evaluateOneRender`-style function returning a `RenderOutcome` (or,
    /// for seam-eval, a non-private `evaluate` returning a page count) —
    /// see the doc comments in the respective harness files, including
    /// the one deliberate behavior change (label-listing failures no
    /// longer abort the whole sweep — Task 9 review, finding 1). None of
    /// this changed any harness's printed `[SUMMARY]` lines or env
    /// gating.
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
        /// harness must take its QUARANTINE branch.
        ///
        /// Asserts the returned `RenderOutcome` BY VALUE (Task 9 review,
        /// finding 2) — checking only "no label file appeared" cannot
        /// distinguish QUARANTINE from `.badRenderJSON`, `.failed`, or a
        /// literal do-nothing stub, all of which satisfy that check
        /// identically.
        @MainActor
        @Test func labelExportHarnessProcessesAWellFormedDirAndQuarantinesIt() throws {
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            switch OMRLabelExportHarness.evaluateOneRender(dir: layout.missingLabelsDir) {
            case .quarantined: break
            case let outcome: Issue.record("expected .quarantined, got \(outcome)")
            }
            let labelsPath = "\(layout.missingLabelsDir)/page_0.labels.json"
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
        /// well-formed directory and for one with no `.labels.json`.
        ///
        /// Asserts the RETURNED PAGE COUNT, not just `aggregate` (Task 9
        /// review, finding 3): the fixture's well-formed page carries no
        /// music glyphs, so `aggregate` stays empty whether or not the
        /// directory was genuinely processed — a traversal bug that
        /// always found zero label files would pass an `aggregate`-only
        /// check for BOTH directories identically. The page count is the
        /// differential signal: `> 0` for well-formed (one page really
        /// was read and decoded), `== 0` for missing-labels (nothing to
        /// read, not a crash).
        @MainActor
        @Test func seamEvalHarnessProcessesWellFormedDirAndNoOpsWithoutLabels() throws {
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            var aggregate: [String: OMRSeamMetrics.ClassCounts] = [:]
            let wellFormedCount = try OMRSeamEvalHarness().evaluate(
                dir: layout.wellFormedDir, aggregate: &aggregate,
            )
            #expect(wellFormedCount > 0)
            // The fixture carries no music glyphs, so there is nothing to
            // aggregate — this is really asserting that reading, decoding,
            // and running every metric function against the label file
            // completed without throwing.
            #expect(aggregate.isEmpty)
            let missingCount = try OMRSeamEvalHarness().evaluate(
                dir: layout.missingLabelsDir, aggregate: &aggregate,
            )
            #expect(missingCount == 0)
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
