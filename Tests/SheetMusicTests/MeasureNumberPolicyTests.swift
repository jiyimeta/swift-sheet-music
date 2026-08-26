#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    struct MeasureNumberPolicyTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Policy predicate

        @Test func systemStartLabelsOnlySystemHeads() {
            let policy = MeasureNumberPolicy.systemStart
            #expect(policy.drawsLabel(displayedNumber: 1, isSystemStart: true))
            #expect(!policy.drawsLabel(displayedNumber: 2, isSystemStart: false))
            #expect(!policy.drawsLabel(displayedNumber: 8, isSystemStart: false))
        }

        @Test func everyMeasureLabelsEverything() {
            let policy = MeasureNumberPolicy.everyMeasure
            #expect(policy == .interval(every: 1))
            for n in 1 ... 8 {
                #expect(policy.drawsLabel(displayedNumber: n, isSystemStart: false))
            }
        }

        @Test func intervalKeepsSystemHeadsAndMultiples() {
            let policy = MeasureNumberPolicy.interval(every: 4)
            #expect(policy.drawsLabel(displayedNumber: 4, isSystemStart: false))
            #expect(policy.drawsLabel(displayedNumber: 8, isSystemStart: false))
            #expect(!policy.drawsLabel(displayedNumber: 5, isSystemStart: false))
            // A system head is labeled whatever the interval says.
            #expect(policy.drawsLabel(displayedNumber: 5, isSystemStart: true))
        }

        /// An interval below 1 would make `isMultiple(of:)` trap on zero
        /// or answer for a negative modulus; both are clamped to "every
        /// measure" rather than rejected, so a host that fails to
        /// validate its own setting cannot crash layout.
        @Test func intervalBelowOneBehavesAsEveryMeasure() {
            for every in [0, -3] {
                let policy = MeasureNumberPolicy.interval(every: every)
                #expect(policy.drawsLabel(displayedNumber: 3, isSystemStart: false))
                #expect(policy.drawsLabel(displayedNumber: 7, isSystemStart: false))
            }
        }

        // MARK: - Layout

        @available(macOS 15.0, iOS 16.0, *)
        @Test func defaultOptionsLabelOnlyTheFirstMeasureOfEachSystem() {
            let document = layout(measureCount: 6, options: .init())
            for system in document.systems {
                for (offset, measure) in system.measures.enumerated() {
                    let label = numberLabel(of: measure)
                    if offset == 0 {
                        #expect(label != nil)
                    } else {
                        #expect(label == nil)
                    }
                }
            }
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func everyMeasurePolicyLabelsEveryMeasure() {
            let document = layout(
                measureCount: 6,
                options: .init(measureNumbers: .everyMeasure),
            )
            let labels = document.systems
                .flatMap(\.measures)
                .sorted { $0.measureIndex < $1.measureIndex }
                .map { numberLabel(of: $0) }
            #expect(labels == ["1", "2", "3", "4", "5", "6"])
        }

        /// The label is suppressed on an anacrusis under `.everyMeasure`
        /// too — the exclusion lives in `displayedMeasureNumber`, and the
        /// policy must not route around it.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func everyMeasurePolicyStillSkipsIrregularMeasures() {
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [])], irregular: true),
                Measure(voices: [Voice(elements: [])]),
                Measure(voices: [Voice(elements: [])]),
            ])
            let document = layout(
                score: score(staff: staff),
                options: .init(measureNumbers: .everyMeasure),
            )
            let labels = document.systems
                .flatMap(\.measures)
                .sorted { $0.measureIndex < $1.measureIndex }
                .map { numberLabel(of: $0) }
            #expect(labels == [nil, "1", "2"])
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func intervalPolicyLabelsMultiplesOnly() {
            let document = layout(
                measureCount: 6,
                options: .init(measureNumbers: .interval(every: 3)),
            )
            let labeled = document.systems
                .flatMap(\.measures)
                .filter { numberLabel(of: $0) != nil }
                .map(\.measureIndex)
            // Measure indices 2 and 5 are displayed numbers 3 and 6.
            // Index 0 rides along as the head of the first system; any
            // further system head is fine too, so only assert those two
            // are present and that no non-head, non-multiple is.
            #expect(labeled.contains(2))
            #expect(labeled.contains(5))
            let systemHeads = Set(document.systems.compactMap(\.measures.first?.measureIndex))
            for index in labeled where !systemHeads.contains(index) {
                #expect([2, 5].contains(index))
            }
        }

        /// The label rides on the top staff only, whatever the policy —
        /// a grand staff must not grow a second column of numbers.
        @available(macOS 15.0, iOS 16.0, *)
        @Test func everyMeasurePolicyLabelsTheTopStaffOnly() {
            let measures = (0 ..< 4).map { _ in Measure(voices: [Voice(elements: [])]) }
            let part = Part(
                id: "1",
                instrument: Instrument(id: "x", longName: "Piano"),
                staves: [Staff(measures: measures), Staff(measures: measures)],
            )
            let document = layout(
                score: Score(division: 480, parts: [part]),
                options: .init(measureNumbers: .everyMeasure),
            )
            for measure in document.systems.flatMap(\.measures) {
                let count = measure.elements.count(where: {
                    if case .measureNumber = $0 { return true } else { return false }
                })
                #expect(count == 1)
            }
        }

        // MARK: - Helpers

        private func score(staff: Staff) -> Score {
            Score(division: 480, parts: [Part(
                id: "1",
                instrument: Instrument(id: "x", longName: "Piano"),
                staves: [staff],
            )])
        }

        @available(macOS 15.0, iOS 16.0, *)
        private func layout(
            measureCount: Int,
            options: ScoreViewOptions,
        ) -> LayoutDocument {
            let measures = (0 ..< measureCount).map { _ in
                Measure(voices: [Voice(elements: [])])
            }
            return layout(score: score(staff: Staff(measures: measures)), options: options)
        }

        @available(macOS 15.0, iOS 16.0, *)
        private func layout(score: Score, options: ScoreViewOptions) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: options, availableWidth: 800)
        }

        private func numberLabel(of measure: LayoutMeasure) -> String? {
            for element in measure.elements {
                if case let .measureNumber(text, _) = element { return text }
            }
            return nil
        }
    }
#endif
