#if os(macOS) || os(iOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("MultiMeasureRest layout integration")
    struct MultiMeasureRestLayoutTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Helpers

        private static func restMeasure() -> Measure {
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        }

        private static func soundingMeasure() -> Measure {
            let n = Note(pitch: 60, tpc: 14)
            return Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [n])),
            ])])
        }

        private static func score(
            _ measures: [Measure],
            systemMeasures: [SystemMeasure]? = nil,
        ) -> Score {
            Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
                systemMeasures: systemMeasures
                    ?? Array(repeating: SystemMeasure(), count: measures.count),
            )
        }

        // MARK: - Tests

        @Test(".disabled emits one LayoutMeasure per source measure")
        func disabledPolicyUnchanged() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([
                Self.soundingMeasure(),
                Self.restMeasure(), Self.restMeasure(),
                Self.restMeasure(), Self.restMeasure(),
                Self.soundingMeasure(),
            ])
            let doc = LayoutEngine.layout(
                score: s, options: ScoreViewOptions(),
                availableWidth: 1200,
            )
            let total = doc.systems.reduce(0) { $0 + $1.measures.count }
            #expect(total == 6)
            for sys in doc.systems {
                for m in sys.measures {
                    #expect(m.multiMeasureRest == nil)
                }
            }
        }

        @Test(".collapse(2) emits one H-bar measure for the rest run")
        func collapsedEmitsOneHBarMeasure() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([
                Self.soundingMeasure(),
                Self.restMeasure(), Self.restMeasure(),
                Self.restMeasure(), Self.restMeasure(),
                Self.soundingMeasure(),
            ])
            let opts = ScoreViewOptions(
                multiMeasureRest: .collapse(minimumMeasures: 2),
            )
            let doc = LayoutEngine.layout(
                score: s, options: opts, availableWidth: 1200,
            )
            let allMeasures = doc.systems.flatMap(\.measures)
            // sounding + H-bar + sounding = 3 emitted measures.
            #expect(allMeasures.count == 3)
            let hbar = allMeasures.first { $0.multiMeasureRest != nil }
            #expect(hbar?.multiMeasureRest == 4)
            // Source-measure indices preserved on each LayoutMeasure.
            let indices = allMeasures.map(\.measureIndex)
            #expect(indices == [0, 1, 5])
        }

        @Test("collapsed measure carries multiMeasureRest LayoutElement")
        func collapsedMeasureCarriesElement() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let s = Self.score([
                Self.restMeasure(), Self.restMeasure(),
                Self.restMeasure(),
            ])
            let opts = ScoreViewOptions(
                multiMeasureRest: .collapse(minimumMeasures: 2),
            )
            let doc = LayoutEngine.layout(
                score: s, options: opts, availableWidth: 800,
            )
            let hbar = doc.systems.flatMap(\.measures)
                .first { $0.multiMeasureRest != nil }
            guard let hbar else {
                Issue.record("no H-bar measure emitted")
                return
            }
            let counts = hbar.elements.compactMap { (el: LayoutElement) -> Int? in
                if case let .multiMeasureRest(n, _) = el { return n }
                return nil
            }
            #expect(counts == [3])
        }

        @Test("rehearsal mark splits the run")
        func rehearsalMarkSplitsRun() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let mark = Measure(voices: [Voice(elements: [
                .rest(duration: .measure),
            ])])
            // Rehearsal mark on measure index 2 splits the
            // surrounding 4-rest run into two 2-rest runs.
            let markSystem = SystemMeasure(elements: [
                PositionedSystemElement(
                    position: .start,
                    element: .rehearsalMark(RehearsalMark(text: "A")),
                ),
            ])
            let s = Self.score(
                [
                    Self.restMeasure(), Self.restMeasure(),
                    mark,
                    Self.restMeasure(), Self.restMeasure(),
                ],
                systemMeasures: [
                    SystemMeasure(), SystemMeasure(),
                    markSystem,
                    SystemMeasure(), SystemMeasure(),
                ],
            )
            let opts = ScoreViewOptions(
                multiMeasureRest: .collapse(minimumMeasures: 2),
            )
            let doc = LayoutEngine.layout(
                score: s, options: opts, availableWidth: 1200,
            )
            let hbarCounts = doc.systems.flatMap(\.measures)
                .compactMap(\.multiMeasureRest)
            // Two separate 2-measure runs, each emitted as one H-bar.
            #expect(hbarCounts == [2, 2])
        }
    }
#endif
