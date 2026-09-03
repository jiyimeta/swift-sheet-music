#if os(macOS)
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// `PagedScoreView` re-derives its own `ScoreViewOptions` instead
    /// of passing the caller's through, because it has to force
    /// `wrapToViewWidth`. That copy has silently dropped every field
    /// added since it was written. This suite is the gate: it walks
    /// the struct's stored properties with `Mirror`, so a field added
    /// tomorrow and forgotten in the copy fails here without anyone
    /// remembering to update a list.
    @Suite("PagedScoreView option copy")
    struct PagedScoreViewOptionsCopyTests {
        /// Every field deliberately different from its default.
        private static func probeOptions() -> ScoreViewOptions {
            ScoreViewOptions(
                staffSize: 33,
                systemGap: 55,
                wrapToViewWidth: false,
                includeTitleFrame: false,
                breakPolicy: .ignoreAll,
                breakIndicatorVisibility: .none,
                graceNoteMag: 0.5,
                smallNoteMag: 0.9,
                multiMeasureRest: .collapse(minimumMeasures: 3),
                showsInvisibleElements: true,
                measureNumbers: .interval(every: 4),
                lyricsVisible: false,
                fixedLayoutWidth: 777,
            )
        }

        private static func fields(
            _ opts: ScoreViewOptions,
        ) -> [String: String] {
            var out: [String: String] = [:]
            for child in Mirror(reflecting: opts).children {
                guard let label = child.label else { continue }
                out[label] = String(describing: child.value)
            }
            return out
        }

        /// The control: proves `probeOptions()` is actually a probe.
        /// If any field there equals its default, the completeness
        /// test below would pass for that field even if the copy
        /// dropped it.
        @Test("every probe field differs from the default")
        func probeIsNotVacuous() {
            let probe = Self.fields(Self.probeOptions())
            let defaults = Self.fields(ScoreViewOptions())
            #expect(!probe.isEmpty)
            #expect(probe.count == defaults.count)
            for (label, value) in probe {
                #expect(
                    value != defaults[label],
                    "probe field \(label) equals its default (\(value)) — pick another value",
                )
            }
        }

        @Test("the copy carries every field except wrapToViewWidth")
        func copyIsComplete() {
            guard #available(macOS 15.0, *) else { return }
            let source = Self.probeOptions()
            let copy = PagedScoreView.pageOptions(from: source)
            let src = Self.fields(source)
            let dst = Self.fields(copy)
            for (label, value) in src where label != "wrapToViewWidth" {
                #expect(
                    dst[label] == value,
                    "PagedScoreView drops \(label): expected \(value), got \(dst[label] ?? "<missing>")",
                )
            }
        }

        @Test("the copy forces wrapToViewWidth on")
        func copyForcesWrapping() {
            guard #available(macOS 15.0, *) else { return }
            let copy = PagedScoreView.pageOptions(
                from: Self.probeOptions(),
            )
            #expect(copy.wrapToViewWidth == true)
        }

        // MARK: - pageWidth

        @Test("fixedLayoutWidth wins over the container width")
        func pageWidthPrefersFixed() {
            guard #available(macOS 15.0, *) else { return }
            let opts = ScoreViewOptions(fixedLayoutWidth: 800)
            #expect(PagedScoreView.pageWidth(
                containerWidth: 400, options: opts,
            ) == 800)
        }

        @Test("without fixedLayoutWidth the container width is used")
        func pageWidthUsesContainerWhenNoFixed() {
            guard #available(macOS 15.0, *) else { return }
            let opts = ScoreViewOptions()
            #expect(PagedScoreView.pageWidth(
                containerWidth: 400, options: opts,
            ) == 400)
        }

        @Test("the staffSize * 4 floor applies to pageWidth")
        func pageWidthFloorApplies() {
            guard #available(macOS 15.0, *) else { return }
            #expect(PagedScoreView.pageWidth(
                containerWidth: 10,
                options: ScoreViewOptions(staffSize: 28),
            ) == 112)
            #expect(PagedScoreView.pageWidth(
                containerWidth: 10,
                options: ScoreViewOptions(staffSize: 28, fixedLayoutWidth: 5),
            ) == 112)
        }
    }
#endif
