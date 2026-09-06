#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// `LayoutOptionsWire.breakIndicatorVisibilityRaw` let a host ask for the authoring badges that
    /// mark measures carrying an explicit `<LayoutBreak>`; nothing answered. The rule for which
    /// measure earns one moved out of the SwiftUI overlay into `BreakIndicators` at the same time,
    /// because two spellings of it is how a badge ends up appearing on one platform and not the
    /// other — or on a measure whose break the current policy is ignoring, which is a lie about the
    /// file.
    @Suite("BreakIndicatorsBridge")
    struct BreakIndicatorsBridgeTests {
        private let _installApple = TestSupport.installApple

        /// Four measures; bar 2 carries a line break and bar 3 a page break, so every policy /
        /// visibility combination has something distinct to include or drop.
        private static func score() -> Score {
            func bar(lineBreak: Bool = false, pageBreak: Bool = false) -> Measure {
                var measure = Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])])
                measure.lineBreak = lineBreak
                measure.pageBreak = pageBreak
                return measure
            }
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "flute"),
                    staves: [Staff(measures: [
                        bar(),
                        bar(lineBreak: true),
                        bar(pageBreak: true),
                        bar(),
                    ])],
                )],
            )
        }

        private static func laidOutHandle(
            visibility: UInt8,
            breakPolicyRaw: UInt8 = 1, // .honor
        ) -> Int64 {
            let handle = scoreTable.insert(score())
            var options = LayoutOptionsWire.verticalDefault
            options.breakIndicatorVisibilityRaw = visibility
            options.breakPolicyRaw = breakPolicyRaw
            _ = nativeComputeLayout(
                scoreHandle: handle,
                pageWidthMM: 210,
                pageHeightMM: 297,
                optionsBlob: options.encodeToData(),
            )
            return handle
        }

        private static func release(_ handle: Int64) {
            LayoutDocumentCache.release(handle)
            scoreTable.release(handle)
        }

        private static func indicators(_ handle: Int64) throws -> [BreakIndicatorWire] {
            let data = nativeBreakIndicators(scoreHandle: handle)
            #expect(!data.isEmpty)
            return try BreakIndicatorsWire(decoding: data).indicators
        }

        /// `.all` (2) shows both kinds. Both breaks are authored, so both badges appear.
        @Test
        func visibilityAllShowsBothKinds() throws {
            let handle = Self.laidOutHandle(visibility: 2)
            defer { Self.release(handle) }
            let found = try Self.indicators(handle)
            #expect(found.count == 2)
            #expect(found.contains { $0.kind == 0 })
            #expect(found.contains { $0.kind == 1 })
        }

        /// `.pageOnly` (1) drops the line badge and keeps the page one.
        @Test
        func visibilityPageOnlyDropsTheLineBadge() throws {
            let handle = Self.laidOutHandle(visibility: 1)
            defer { Self.release(handle) }
            let found = try Self.indicators(handle)
            #expect(found.count == 1)
            #expect(found.first?.kind == 1)
        }

        /// `.none` (0) is the default, and the answer is a decodable EMPTY LIST rather than no
        /// answer — a host that cannot tell those apart shows stale badges for a released handle.
        @Test
        func visibilityNoneAnswersWithAnEmptyList() throws {
            let handle = Self.laidOutHandle(visibility: 0)
            defer { Self.release(handle) }
            #expect(try Self.indicators(handle).isEmpty)
        }

        /// The policy gates BEFORE the visibility does, and it has to: under `.ignoreSystemBreaks`
        /// the engine does not act on an authored line break at all, so its badge would point at a
        /// break that is not happening — even with visibility set to `.all`.
        @Test
        func ignoringSystemBreaksAlsoHidesTheirBadges() throws {
            let handle = Self.laidOutHandle(visibility: 2, breakPolicyRaw: 2)
            defer { Self.release(handle) }
            let found = try Self.indicators(handle)
            #expect(found.count == 1)
            #expect(found.first?.kind == 1)
        }

        /// `.ignoreAll` honours no break, so it earns no badge whatever the visibility says.
        @Test
        func ignoringAllBreaksHidesEveryBadge() throws {
            let handle = Self.laidOutHandle(visibility: 2, breakPolicyRaw: 3)
            defer { Self.release(handle) }
            #expect(try Self.indicators(handle).isEmpty)
        }

        /// A badge sits at its measure's trailing edge, where the break happens — not at its start.
        @Test
        func aBadgeSitsAtItsMeasuresTrailingEdge() throws {
            let handle = Self.laidOutHandle(visibility: 2)
            defer { Self.release(handle) }
            let entry = try #require(LayoutDocumentCache.entry(for: handle))
            let ptToMM = 25.4 / 72.0
            let expected = entry.document.systems.flatMap { system in
                system.measures.filter { $0.lineBreak || $0.pageBreak }.map {
                    Double(system.origin.x + $0.origin.x + $0.width) * ptToMM
                }
            }.sorted()
            let actual = try Self.indicators(handle).map(\.xMm).sorted()
            #expect(actual.count == expected.count)
            for (a, e) in zip(actual, expected) {
                #expect(abs(a - e) < 1e-9)
            }
        }

        /// "No answer" stays empty `Data`, distinct from the empty list above.
        @Test
        func anUnknownHandleAnswersWithNoData() {
            #expect(nativeBreakIndicators(scoreHandle: 0).isEmpty)
        }

        @Test
        func aScoreWithNoCachedLayoutAnswersWithNoData() {
            let handle = scoreTable.insert(Self.score())
            defer { scoreTable.release(handle) }
            #expect(nativeBreakIndicators(scoreHandle: handle).isEmpty)
        }

        // MARK: - The shared rule

        /// The Apple overlay now delegates to this, so these cases pin what BOTH renderers do.
        @Test(arguments: [
            (LayoutBreakPolicy.honor, BreakIndicatorVisibility.all, true, true),
            (.honor, .pageOnly, false, true),
            (.honor, BreakIndicatorVisibility.none, false, false),
            (.ignoreSystemBreaks, .all, false, true),
            (.ignoreAll, .all, false, false),
        ])
        func theSharedRuleGatesPolicyBeforeVisibility(
            policy: LayoutBreakPolicy,
            visibility: BreakIndicatorVisibility,
            expectsLine: Bool,
            expectsPage: Bool,
        ) {
            // `LayoutMeasure` is what the rule reads; build one per case rather than laying a score
            // out, so the assertion is about the rule and not about the engine around it.
            #expect(
                (BreakIndicators.kind(
                    for: Self.layoutMeasure(lineBreak: true), policy: policy, visibility: visibility,
                ) == .line) == expectsLine,
            )
            #expect(
                (BreakIndicators.kind(
                    for: Self.layoutMeasure(pageBreak: true), policy: policy, visibility: visibility,
                ) == .page) == expectsPage,
            )
        }

        /// A page break wins over a line break on the same measure — MuseScore's page break implies
        /// a system break, so showing the line badge would name the lesser of the two.
        @Test
        func aPageBreakWinsOverALineBreakOnTheSameMeasure() {
            #expect(
                BreakIndicators.kind(
                    for: Self.layoutMeasure(lineBreak: true, pageBreak: true),
                    policy: .honor,
                    visibility: .all,
                ) == .page,
            )
        }

        private static func layoutMeasure(
            lineBreak: Bool = false, pageBreak: Bool = false,
        ) -> LayoutMeasure {
            LayoutMeasure(
                measureIndex: 0,
                origin: .zero,
                width: 100,
                elements: [],
                lineBreak: lineBreak,
                pageBreak: pageBreak,
            )
        }
    }
#endif
