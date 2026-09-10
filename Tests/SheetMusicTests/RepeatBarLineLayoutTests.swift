#if os(macOS)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// MuseScore stores a repeat as a FLAG on the measure
    /// (`<startRepeat/>` / `<endRepeat>`), not as a `<BarLine>` element,
    /// so layout has to synthesize the barline the flag implies.
    @Suite("Repeat barlines from measure flags")
    struct RepeatBarLineLayoutTests {
        private let _installApple = TestSupport.installApple

        /// Every barline subtype emitted for `measure`, across all
        /// staves and systems. `nil` entries (plain single barlines)
        /// are preserved, so a caller can assert on their absence.
        private static func barSubtypes(
            in doc: LayoutDocument, measure: Int,
        ) -> [String?] {
            var result: [String?] = []
            for system in doc.systems {
                for m in system.measures where m.measureIndex == measure {
                    for element in m.elements {
                        if case let .barLine(subtype, _, _, _, _) = element {
                            result.append(subtype)
                        }
                    }
                }
            }
            return result
        }

        @Test("start and end repeat flags on the canonical staff draw repeat barlines on every staff")
        func flagsDrawRepeatBars() {
            var score = EditingFixtures.parityFixture()
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[1].startRepeat = true
                }
            }
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[2].endRepeatCount = 2
                }
            }
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 900,
            )
            let m1 = Self.barSubtypes(in: doc, measure: 1)
            let m2 = Self.barSubtypes(in: doc, measure: 2)
            #expect(
                m1.filter { $0 == "start-repeat" }.count == 2,
                "one start-repeat per staff",
            )
            #expect(
                m2.filter { $0 == "end-repeat" }.count == 2,
                "one end-repeat per staff",
            )
            #expect(
                m2.filter { $0 == nil }.isEmpty,
                "the trailing bar is replaced, not duplicated",
            )
        }

        @Test("an explicit end-repeat BarLine element is not drawn twice")
        func explicitBarNotDuplicated() {
            var score = EditingFixtures.parityFixture()
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[2].endRepeatCount = 2
                }
            }
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    var elements = staffValue.measures[2].voices[0].elements.values
                    elements.append(.barLine(BarLine(subtype: "end-repeat")))
                    staffValue.measures[2].voices[0].elements = IdentifiedArray(elements)
                }
            }
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 900,
            )
            #expect(
                Self.barSubtypes(in: doc, measure: 2)
                    .filter { $0 == "end-repeat" }.count == 2,
            )
        }

        @Test("a score without repeat flags lays out exactly as before")
        func noFlagsUnchanged() {
            let score = EditingFixtures.parityFixture()
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 900,
            )
            #expect(Self.barSubtypes(in: doc, measure: 1).allSatisfy { $0 == nil })
            #expect(Self.barSubtypes(in: doc, measure: 3).allSatisfy { $0 == "end" })
            #expect(Self.barSubtypes(in: doc, measure: 3).count == 2)
        }
    }
#endif
