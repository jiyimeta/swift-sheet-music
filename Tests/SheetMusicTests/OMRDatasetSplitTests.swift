#if !os(Android) && !os(WASI)
    import Foundation
    import Testing

    @Suite("OMR dataset split — parity with Training/model/prep.py")
    struct OMRDatasetSplitTests {
        /// The table is GENERATED from `prep.split_of`, not hand-written:
        /// every row is that function's own answer for the given
        /// (source_id, page_index, seed). A hand-written expectation
        /// would only pin what its author believed the Python side did.
        ///
        /// It deliberately covers all three buckets and both seeds in
        /// play (`20260811`, the seed `run1` trained under, and `0`, the
        /// unit-test seed `Training/tests/test_train.py` brute-forced its
        /// fixtures against) — a table that never lands on `.val` or
        /// `.test` passes against an implementation that answers
        /// `.train` unconditionally.
        @Test("the split matches the Python table")
        func theSplitMatchesThePythonTable() {
            let cases: [(String, Int, Int, OMRDatasetSplit)] = [
                ("cov_clef_changes", 0, 20_260_811, .test),
                ("cov_clef_changes", 4, 20_260_811, .train),
                ("tex_0076", 0, 20_260_811, .train),
                ("tex_0076", 1, 20_260_811, .train),
                ("src_0", 0, 0, .train),
                ("src_1", 0, 0, .train),
                ("src_10", 0, 0, .val),
                ("cov_dots", 2, 20_260_811, .train),
                ("cov_flags", 0, 20_260_811, .val),
                ("cov_ornaments", 3, 20_260_811, .train),
                ("", 0, 0, .test),
                ("a_b_c", 999, 7, .train),
            ]
            for (sourceId, pageIndex, seed, expected) in cases {
                #expect(
                    OMRDatasetSplit.of(sourceId: sourceId, pageIndex: pageIndex, seed: seed)
                        == expected,
                    "split_of(\(sourceId), \(pageIndex), seed: \(seed))",
                )
            }
            // Anti-vacuity: the table must actually exercise all three
            // buckets, or "matches Python" is a claim about one branch.
            let buckets = Set(cases.map(\.3))
            #expect(buckets == [.train, .val, .test])
        }

        /// The seed is part of the key, so the same page must be free to
        /// land in a different bucket under a different seed. Without
        /// this, an implementation that ignored `seed` entirely would
        /// still pass the table above for any single seed.
        @Test("the seed changes the bucket")
        func theSeedChangesTheBucket() {
            let differs = (0 ..< 50).contains { seed in
                OMRDatasetSplit.of(sourceId: "cov_clef_changes", pageIndex: 0, seed: seed)
                    != OMRDatasetSplit.of(sourceId: "cov_clef_changes", pageIndex: 0, seed: 20_260_811)
            }
            #expect(differs)
        }

        /// `render.json` is authoritative when present; the render-id
        /// parse is only the FROZEN fallback.
        @Test("a recorded source id wins over the render-id parse")
        func aRecordedSourceIdWinsOverTheRenderIDParse() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("omr-split-\(UUID().uuidString)")
                // A directory name whose parse would give the WRONG
                // answer, so "recorded wins" is observable.
                .appendingPathComponent("not_the_source_ms4_Bravura_v0")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            try Data(#"{"provenance": {"source_id": "recorded_id"}}"#.utf8)
                .write(to: dir.appendingPathComponent("render.json"))

            #expect(OMRDatasetSplit.sourceId(renderDirectory: dir.path) == "recorded_id")
            #expect(OMRDatasetSplit.sourceId(fromRenderID: dir.lastPathComponent) == "not_the_source")
        }

        @Test("a frozen directory falls back to the render-id parse")
        func aFrozenDirectoryFallsBackToTheRenderIDParse() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("omr-split-\(UUID().uuidString)")
                .appendingPathComponent("cov_clef_changes_ms4_Petaluma_v9")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
            // frozen.json carries no provenance — that IS the case this
            // fallback exists for.
            try Data(#"{"render_id": "cov_clef_changes_ms4_Petaluma_v9"}"#.utf8)
                .write(to: dir.appendingPathComponent("frozen.json"))

            #expect(OMRDatasetSplit.sourceId(renderDirectory: dir.path) == "cov_clef_changes")
        }

        @Test("a render id with too few components has no source id")
        func aRenderIDWithTooFewComponentsHasNoSourceID() {
            #expect(OMRDatasetSplit.sourceId(fromRenderID: "ms4_Bravura_v0") == nil)
            #expect(OMRDatasetSplit.sourceId(fromRenderID: "onlyone") == nil)
        }

        /// The parse rule checked against the WHOLE clean dataset rather
        /// than a handful of names: for every render that records a
        /// `source_id`, the render-id parse must reproduce it. Skipped
        /// when `OMR_DATA_ROOT` is unset, and it prints the population it
        /// checked — a run over zero renders would otherwise pass while
        /// checking nothing.
        @Test(
            "the recovered source id agrees with every recorded one",
            .enabled(if: ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] != nil),
        )
        func theRecoveredSourceIDAgreesWithEveryRecordedOne() throws {
            let root = try #require(ProcessInfo.processInfo.environment["OMR_DATA_ROOT"])
            let dirs = try OMRHarnessDirectoryWalk.renderOrFrozenDirectories(root: root)
            var checked = 0
            var disagreed: [String] = []
            for dir in dirs {
                guard let recorded = OMRDatasetSplit.recordedSourceId(renderDirectory: dir)
                else { continue }
                checked += 1
                let parsed = OMRDatasetSplit
                    .sourceId(fromRenderID: (dir as NSString).lastPathComponent)
                if parsed != recorded { disagreed.append("\(dir): \(parsed ?? "nil") != \(recorded)") }
            }
            print("[split-parse] renders=\(dirs.count) withRecordedSourceID=\(checked) "
                + "disagreed=\(disagreed.count)")
            #expect(disagreed.isEmpty, "\(disagreed.prefix(10))")
            #expect(checked > 0, "no render under \(root) recorded a source_id — nothing was checked")
        }
    }
#endif
