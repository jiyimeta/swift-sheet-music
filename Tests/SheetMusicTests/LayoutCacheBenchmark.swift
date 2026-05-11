// swiftlint:disable function_body_length file_length
#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// One-off benchmark for the LayoutCache. Disabled by default —
    /// set `SHEETMUSIC_RUN_LAYOUT_BENCH=1` in the environment to opt in.
    /// Loads `Example/SheetMusicExample/test.mscx` (1356 measures) from
    /// the package root and reports cold / warm / single-edit timings.
    @Suite("LayoutCacheBenchmark", .enabled(
        if:
        ProcessInfo.processInfo.environment[
            "SHEETMUSIC_RUN_LAYOUT_BENCH",
        ] == "1",
    ))
    struct LayoutCacheBenchmark {
        @Test("test.mscx: cold vs warm vs single-edit")
        func benchmark() throws {
            guard #available(macOS 15.0, *) else { return }
            // Test process cwd is the package root.
            let path = "Example/SheetMusicExample/test.mscx"
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let score = try MSCXParser.parse(data)
            let measureCount = score.allStaves.first?.staff.measures.count ?? 0
            print("score: \(measureCount) measures, \(score.totalStaffCount) staves")
            let opts = ScoreViewOptions()
            let availableWidth = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )

            // --- Cold: cache-less ---
            let coldT0 = Date()
            _ = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: availableWidth,
            )
            let coldMs = Date().timeIntervalSince(coldT0) * 1000
            print(String(format: "cold (no cache):       %7.1f ms", coldMs))

            // --- Cold with cache: populates the cache ---
            let cache = LayoutCache()
            let coldCacheT0 = Date()
            _ = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: availableWidth, cache: cache,
            )
            let coldCacheMs = Date().timeIntervalSince(coldCacheT0) * 1000
            print(String(
                format: "cold (populate cache): %7.1f ms",
                coldCacheMs,
            ))

            // --- Warm: identical score, full cache hits ---
            let warmT0 = Date()
            _ = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: availableWidth, cache: cache,
            )
            let warmMs = Date().timeIntervalSince(warmT0) * 1000
            print(String(
                format: "warm (all cached):     %7.1f ms",
                warmMs,
            ))
            print(
                "warm hits: width=\(cache.widthHits) "
                    + "placement=\(cache.placementHits)",
            )
            print(String(
                format: "  speedup vs cold:    %.0f%% "
                    + "(saved %.1f ms)",
                (1 - warmMs / coldMs) * 100,
                coldMs - warmMs,
            ))

            // --- Single-measure edit: replace pitch in a chord ---
            let firstStave = score.allStaves.first?.staff
            if let firstStave,
               let editIdx = pickEditableMeasure(staff: firstStave)
            {
                var measures = firstStave.measures
                let original = measures[editIdx]
                measures[editIdx] = bumpFirstChord(in: original)
                var editedParts = score.parts
                if !editedParts.isEmpty && !editedParts[0].staves.isEmpty {
                    editedParts[0].staves[0] = Staff(measures: measures)
                }
                let edited = Score(
                    division: score.division,
                    parts: editedParts,
                    metaTags: score.metaTags,
                    titleFrame: score.titleFrame,
                    style: score.style,
                )
                let editT0 = Date()
                _ = LayoutEngine.layout(
                    score: edited, options: opts,
                    availableWidth: availableWidth, cache: cache,
                )
                let editMs = Date().timeIntervalSince(editT0) * 1000
                print(String(
                    format: "edit (1 measure):      %7.1f ms",
                    editMs,
                ))
                print(
                    "edit hits/misses: width=\(cache.widthHits)/"
                        + "\(cache.widthMisses) placement="
                        + "\(cache.placementHits)/\(cache.placementMisses)",
                )
            }
        }

        /// Find a measure with a pitched chord we can mutate.
        private func pickEditableMeasure(staff: Staff) -> Int? {
            for (idx, m) in staff.measures.enumerated() {
                for v in m.voices {
                    for el in v.elements {
                        if case let .chord(c) = el,
                           !c.notes.isEmpty
                        {
                            return idx
                        }
                    }
                }
            }
            return nil
        }

        /// Replace the first chord's first note's pitch (cheap edit).
        private func bumpFirstChord(in measure: Measure) -> Measure {
            var voices = measure.voices
            for vi in voices.indices {
                var elements = voices[vi].elements
                for ei in elements.indices {
                    if case var .chord(c) = elements[ei], !c.notes.isEmpty {
                        let n = c.notes[0]
                        c.notes[0] = Note(
                            pitch: n.pitch == 60 ? 62 : 60,
                            tpc: n.pitch == 60 ? 16 : 14,
                        )
                        elements[ei] = .chord(c)
                        voices[vi] = Voice(elements: elements)
                        return Measure(
                            voices: voices,
                            lineBreak: measure.lineBreak,
                            pageBreak: measure.pageBreak,
                        )
                    }
                }
            }
            return measure
        }
    }
#endif
