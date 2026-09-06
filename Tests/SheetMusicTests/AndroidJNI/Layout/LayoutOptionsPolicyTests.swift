#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// `LayoutOptionsWire` carried five of `ScoreViewOptions`' twelve knobs, and `LayoutBridge`
    /// hard-coded the rest — the measure-number policy was pinned to `.systemStart`, the
    /// break-indicator visibility to `.none`, the multi-measure-rest threshold to 2, and the
    /// three-way `LayoutBreakPolicy` was flattened into a boolean that could not express
    /// `.ignoreSystemBreaks` at all.
    ///
    /// Every new field defaults to what the bridge hard-coded, so the compatibility claim — an
    /// unchanged host gets an unchanged layout — is the thing most of these tests assert.
    struct LayoutOptionsPolicyTests {
        /// The two "reaches the engine" tests call `LayoutBridge.computeWithDocument`, which asserts
        /// that a real `FontMetricsProvider` is installed on a CoreText-capable platform.
        private let _installApple = TestSupport.installApple

        // MARK: - Compatibility

        /// The whole appended-fields argument in one assertion: the wire a host built before these
        /// fields existed still decodes, and every derived value is what `LayoutBridge` used to
        /// hard-code.
        @Test
        func theLegacyWireDecodesToTheOldHardCodedBehaviour() throws {
            let legacy = LayoutOptionsWire(
                layoutMode: 0, staffSize: 28,
                honorLayoutBreaks: 1, collapseMultiMeasureRests: 1, showsInvisibleElements: 0,
                hiddenStaves: [], clefOverrides: [], transposeSemitones: 0,
            )
            let wire = try LayoutOptionsWire(decoding: legacy.encodeToData())
            #expect(wire.breakPolicy == .honor)
            #expect(wire.multiMeasureRestPolicy == .collapse(minimumMeasures: 2))
            #expect(wire.measureNumberPolicy == .systemStart)
            #expect(wire.breakIndicatorVisibility == .none)
            #expect(wire.systemGap(staffSize: 28) == 28 * 1.25)
            #expect(wire.includesTitleFrame(modeDefault: true))
            #expect(!wire.includesTitleFrame(modeDefault: false))
            #expect(wire.graceNoteMag == 0)
            #expect(wire.smallNoteMag == 0)
        }

        /// The reason `breakPolicyRaw == 0` defers instead of meaning `.honor`: a host sending the
        /// old boolean as `0` means `.ignoreAll`, and a new field that overrode it with `.honor`
        /// would silently flip that host's layout the moment it shipped.
        @Test
        func breakPolicyZeroDefersToTheOlderBoolean() {
            var wire = LayoutOptionsWire.verticalDefault
            wire.honorLayoutBreaks = 0
            #expect(wire.breakPolicy == .ignoreAll)
            wire.honorLayoutBreaks = 1
            #expect(wire.breakPolicy == .honor)
        }

        // MARK: - New reach

        /// The case the boolean could not express at all: ignore `<LayoutBreak>line`, still honor
        /// `page`.
        @Test
        func breakPolicyReachesIgnoreSystemBreaks() {
            var wire = LayoutOptionsWire.verticalDefault
            wire.honorLayoutBreaks = 1
            wire.breakPolicyRaw = 2
            #expect(wire.breakPolicy == .ignoreSystemBreaks)
        }

        /// An explicit raw value wins over the boolean in both directions, so a host that has moved
        /// to the new field never has to keep the old one in sync.
        @Test(arguments: [(UInt8(1), LayoutBreakPolicy.honor), (3, .ignoreAll)])
        func anExplicitBreakPolicyOverridesTheBoolean(raw: UInt8, expected: LayoutBreakPolicy) {
            var wire = LayoutOptionsWire.verticalDefault
            wire.honorLayoutBreaks = raw == 1 ? 0 : 1 // deliberately the opposite of `expected`
            wire.breakPolicyRaw = raw
            #expect(wire.breakPolicy == expected)
        }

        @Test
        func measureNumberIntervalReachesTheIntervalPolicy() {
            var wire = LayoutOptionsWire.verticalDefault
            wire.measureNumberInterval = 4
            #expect(wire.measureNumberPolicy == .interval(every: 4))
            wire.measureNumberInterval = 1
            #expect(wire.measureNumberPolicy == .everyMeasure)
        }

        @Test
        func multiMeasureRestMinimumIsHonoured() {
            var wire = LayoutOptionsWire.verticalDefault
            wire.collapseMultiMeasureRests = 1
            wire.multiMeasureRestMinimum = 6
            #expect(wire.multiMeasureRestPolicy == .collapse(minimumMeasures: 6))
        }

        /// Clamped in the same direction `LayoutPaginator` clamps, rather than adding a second rule
        /// a host would have to know about.
        @Test(arguments: [Int32(0), 1, -3])
        func aMinimumBelowTwoClampsToTwo(minimum: Int32) {
            var wire = LayoutOptionsWire.verticalDefault
            wire.collapseMultiMeasureRests = 1
            wire.multiMeasureRestMinimum = minimum
            #expect(wire.multiMeasureRestPolicy == .collapse(minimumMeasures: 2))
        }

        /// The threshold is inert while collapsing is off, so a host can carry a preferred value
        /// without it taking effect the moment some other option changes.
        @Test
        func theMinimumIsIgnoredWhileCollapsingIsOff() {
            var wire = LayoutOptionsWire.verticalDefault
            wire.collapseMultiMeasureRests = 0
            wire.multiMeasureRestMinimum = 6
            #expect(wire.multiMeasureRestPolicy == .disabled)
        }

        @Test(arguments: [
            (UInt8(0), BreakIndicatorVisibility.none),
            (1, .pageOnly),
            (2, .all),
        ])
        func breakIndicatorVisibilityMapsEachCase(raw: UInt8, expected: BreakIndicatorVisibility) {
            var wire = LayoutOptionsWire.verticalDefault
            wire.breakIndicatorVisibilityRaw = raw
            #expect(wire.breakIndicatorVisibility == expected)
        }

        @Test
        func anExplicitSystemGapOverridesTheDerivedOne() {
            var wire = LayoutOptionsWire.verticalDefault
            wire.systemGapPoints = 40
            #expect(wire.systemGap(staffSize: 28) == 40)
        }

        @Test(arguments: [(UInt8(0), false), (1, true)])
        func titleFrameCanBeForcedInEitherDirection(raw: UInt8, expected: Bool) {
            var wire = LayoutOptionsWire.verticalDefault
            wire.includeTitleFrameRaw = raw
            // Both mode defaults give the forced answer — that is what "forced" means.
            #expect(wire.includesTitleFrame(modeDefault: true) == expected)
            #expect(wire.includesTitleFrame(modeDefault: false) == expected)
        }

        // MARK: - Reaching the engine

        /// Threading a value through the wire is worth nothing if `LayoutBridge` drops it, and the
        /// bridge's `ScoreViewOptions` construction is private. This asserts the observable end of
        /// it: a measure-number interval changes the engraved document.
        @Test
        func theMeasureNumberIntervalReachesTheLayout() {
            let score = Self.eightBarScore()
            var wire = LayoutOptionsWire.verticalDefault
            let plain = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: wire,
            )
            wire.measureNumberInterval = 1
            let everyBar = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: wire,
            )
            #expect(Self.measureNumberCount(everyBar.document) > Self.measureNumberCount(plain.document))
        }

        /// The system gap is geometry, so an explicit one has to move the systems.
        @Test
        func anExplicitSystemGapReachesTheLayout() {
            let score = Self.eightBarScore()
            var wire = LayoutOptionsWire.verticalDefault
            wire.staffSize = 28
            let derived = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: wire,
            )
            wire.systemGapPoints = 200
            let wide = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: wire,
            )
            #expect(wide.document.size.height > derived.document.size.height)
        }

        // MARK: - Fixtures

        /// Eight one-bar measures, enough to wrap into more than one system at A4 width so the
        /// system gap and the measure-number policy both have something to act on.
        private static func eightBarScore() -> Score {
            let measures = (0 ..< 8).map { index in
                var elements: [VoiceElement] = []
                if index == 0 {
                    elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
                }
                elements.append(contentsOf: (0 ..< 4).map { _ in
                    VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
                })
                return Measure(voices: [Voice(elements: elements)])
            }
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
            )
        }

        private static func measureNumberCount(_ document: LayoutDocument) -> Int {
            document.systems.reduce(0) { total, system in
                total + system.measures.reduce(0) { measureTotal, measure in
                    measureTotal + measure.elements.count { element in
                        if case .measureNumber = element { true } else { false }
                    }
                }
            }
        }
    }
#endif
