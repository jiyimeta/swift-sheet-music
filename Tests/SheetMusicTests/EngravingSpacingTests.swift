#if os(macOS) || os(iOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("Engraving spacing")
    struct EngravingSpacingTests {
        private let _installApple = TestSupport.installApple

        // MARK: - Helpers

        private static func chord(_ duration: NoteDuration = .quarter) -> VoiceElement {
            .chord(Chord(
                duration: duration,
                notes: [Note(pitch: 60, tpc: 14)],
            ))
        }

        private static func score(measures: [Measure]) -> Score {
            Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
        }

        private static func quarterScore(measureCount: Int = 4) -> Score {
            let measure = Measure(voices: [Voice(elements: [
                chord(), chord(), chord(), chord(),
            ])])
            return score(
                measures: Array(repeating: measure, count: measureCount),
            )
        }

        /// Three staggered voices make the middle adjacent-column gap
        /// 0.8 sp before `minNoteDistance` is applied.
        private static func staggeredVoiceScore() -> Score {
            let quarterShift = Fraction(numerator: 1, denominator: 4)
            let threeEighthsShift = Fraction(numerator: 3, denominator: 8)
            let measure = Measure(voices: [
                Voice(elements: [chord(.whole)]),
                Voice(elements: [
                    .locationShift(delta: quarterShift),
                    chord(.half),
                ]),
                Voice(elements: [
                    .locationShift(delta: threeEighthsShift),
                    chord(.half),
                ]),
            ])
            return score(measures: [measure])
        }

        private static func horizontalOptions(
            spacing: EngravingSpacing = .standard,
        ) -> ScoreViewOptions {
            ScoreViewOptions(
                staffSize: 20,
                wrapToViewWidth: false,
                includeTitleFrame: false,
                spacing: spacing,
            )
        }

        private static func firstMeasureWidth(_ document: LayoutDocument) -> CGFloat? {
            document.systems.first?.measures.first?.width
        }

        // MARK: - Defaults

        @Test("implicit and explicit standard spacing are equivalent")
        func defaultEquivalence() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.quarterScore()
            let implicit = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 300,
            )
            let explicit = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(spacing: .standard),
                availableWidth: 300,
            )

            #expect(implicit.size == explicit.size)
            #expect(implicit.systems.map(\.origin) == explicit.systems.map(\.origin))
        }

        // MARK: - Horizontal spacing

        @Test("minNoteDistance widens adjacent note columns by its exact floor")
        func minNoteDistanceWidens() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.staggeredVoiceScore()
            let baseline = LayoutEngine.layout(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    minNoteDistance: 0,
                    systemStretch: 1,
                )),
                availableWidth: 800,
            )
            let widened = LayoutEngine.layout(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    minNoteDistance: 1,
                    systemStretch: 1,
                )),
                availableWidth: 800,
            )
            guard let baselineWidth = Self.firstMeasureWidth(baseline),
                  let widenedWidth = Self.firstMeasureWidth(widened)
            else {
                Issue.record("expected one laid-out measure")
                return
            }

            #expect(widenedWidth > baselineWidth)
            // staffSize 20 => sp 5. The sole affected gap rises from
            // 0.8 sp to 1 sp, so the exact width delta is 0.2 * 5 = 1 pt.
            #expect(widenedWidth - baselineWidth == 1)
        }

        @Test("spacePerQuarter scales measure width")
        func spacePerQuarterScales() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.quarterScore(measureCount: 1)
            let standard = LayoutEngine.layout(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    spacePerQuarter: 1.6,
                    systemStretch: 1,
                )),
                availableWidth: 800,
            )
            let halved = LayoutEngine.layout(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    spacePerQuarter: 0.8,
                    systemStretch: 1,
                )),
                availableWidth: 800,
            )
            guard let standardWidth = Self.firstMeasureWidth(standard),
                  let halvedWidth = Self.firstMeasureWidth(halved)
            else {
                Issue.record("expected one laid-out measure")
                return
            }

            #expect(halvedWidth < standardWidth)
        }

        @Test("naturalContentWidth honors spacePerQuarter")
        func naturalContentWidthHonorsSpacing() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.quarterScore(measureCount: 1)
            let standard = LayoutEngine.naturalContentWidth(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    spacePerQuarter: 1.6,
                )),
            )
            let halved = LayoutEngine.naturalContentWidth(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    spacePerQuarter: 0.8,
                )),
            )

            #expect(halved < standard)
        }

        @Test("warm cache invalidates widths when spacing changes")
        func cacheIncludesSpacing() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.staggeredVoiceScore()
            let cache = LayoutCache()
            let baseline = LayoutEngine.layout(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    minNoteDistance: 0,
                    systemStretch: 1,
                )),
                availableWidth: 800,
                cache: cache,
            )
            let widened = LayoutEngine.layout(
                score: score,
                options: Self.horizontalOptions(spacing: EngravingSpacing(
                    minNoteDistance: 1,
                    systemStretch: 1,
                )),
                availableWidth: 800,
                cache: cache,
            )
            guard let baselineWidth = Self.firstMeasureWidth(baseline),
                  let widenedWidth = Self.firstMeasureWidth(widened)
            else {
                Issue.record("expected one laid-out measure")
                return
            }

            #expect(widenedWidth - baselineWidth == 1)
            #expect(cache.widthMisses == 1)
        }

        // MARK: - Margins

        @Test("leading and trailing margins stay outside music width")
        func horizontalMargins() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.quarterScore()
            let baseline = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 20),
                availableWidth: 300,
            )
            let margined = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 20,
                    spacing: EngravingSpacing(margins: EngravingMargins(
                        leading: 3,
                        trailing: 5,
                    )),
                ),
                availableWidth: 300,
            )

            #expect(margined.systems.count == baseline.systems.count)
            for (plain, shifted) in zip(baseline.systems, margined.systems) {
                // leading 3 sp * 5 pt/sp = 15 pt.
                #expect(shifted.origin.x - plain.origin.x == 15)
                #expect(shifted.size.width == plain.size.width)
            }
            // (leading 3 + trailing 5 - default trailing 2) * 5 = 30 pt.
            #expect(margined.size.width - baseline.size.width == 30)
        }

        @Test("top and bottom margins stay outside music height")
        func verticalMargins() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.quarterScore()
            let baseline = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 20),
                availableWidth: 300,
            )
            let margined = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 20,
                    spacing: EngravingSpacing(margins: EngravingMargins(
                        top: 3,
                        bottom: 2,
                    )),
                ),
                availableWidth: 300,
            )

            #expect(margined.systems.count == baseline.systems.count)
            for (plain, shifted) in zip(baseline.systems, margined.systems) {
                // top 3 sp * 5 pt/sp = 15 pt.
                #expect(shifted.origin.y - plain.origin.y == 15)
            }
            // (top 3 + bottom 2) * 5 = 25 pt.
            #expect(margined.size.height - baseline.size.height == 25)
        }

        // MARK: - System indents

        @Test("firstSystemIndent changes only the label-width floor")
        func firstSystemIndentFloor() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.quarterScore(measureCount: 1)
            func firstStaffX(indent: CGFloat) -> CGFloat? {
                let document = LayoutEngine.layout(
                    score: score,
                    options: Self.horizontalOptions(spacing: EngravingSpacing(
                        systemStretch: 1,
                        firstSystemIndent: indent,
                    )),
                    availableWidth: 800,
                )
                return document.systems.first?.staffOrigins.first?.x
            }
            guard let defaultX = firstStaffX(indent: 4),
                  let largerX = firstStaffX(indent: 6),
                  let zeroX = firstStaffX(indent: 0)
            else {
                Issue.record("expected one staff origin")
                return
            }

            // In the floor-dominant range, 6 sp - 4 sp = 2 sp = 10 pt.
            #expect(largerX - defaultX == 10)
            // labelWidth is max(floor, widest + pad), with pad = 1 sp.
            // Lowering the floor below 1 sp leaves that label pad as the
            // minimum: 1 sp - 4 sp = -3 sp = -15 pt. This option changes
            // only the floor; it deliberately does not remove the pad.
            #expect(zeroX - defaultX == -15)
        }

        @Test("continuationSystemIndent changes continuation floor")
        func continuationSystemIndentFloor() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let first = Measure(
                voices: [Voice(elements: [Self.chord(.whole)])],
                lineBreak: true,
            )
            let second = Measure(voices: [Voice(elements: [
                Self.chord(.whole),
            ])])
            let score = Self.score(measures: [first, second])
            func continuationX(indent: CGFloat) -> CGFloat? {
                let document = LayoutEngine.layout(
                    score: score,
                    options: ScoreViewOptions(
                        staffSize: 20,
                        spacing: EngravingSpacing(
                            continuationSystemIndent: indent,
                        ),
                    ),
                    availableWidth: 800,
                )
                guard document.systems.count == 2 else { return nil }
                return document.systems[1].staffOrigins.first?.x
            }
            guard let defaultX = continuationX(indent: 2),
                  let largerX = continuationX(indent: 4)
            else {
                Issue.record("expected a continuation system")
                return
            }

            // 4 sp - 2 sp = 2 sp; staffSize 20 makes that 10 pt.
            #expect(largerX - defaultX == 10)
        }
    }
#endif
