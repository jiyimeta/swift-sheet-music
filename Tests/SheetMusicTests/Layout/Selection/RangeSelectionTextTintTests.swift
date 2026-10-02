#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// A range selection tints the staff and system texts its copy carries, through the same layers a single-text
    /// selection tints.
    ///
    /// Asserted on the built CALayers' fill after `applySelection`, not on the ID set alone. The ID set can name
    /// a text the layout identifies differently, and then no layer turns blue. That is the failure this guards
    /// against: `Score.rangeTextIDs(for:)` names its anchors itself, and the layout names them separately.
    @Suite("Range selection — texts", .serialized)
    struct RangeSelectionTextTintTests {
        private let _installApple = TestSupport.installApple

        private static let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let bottom = StaffAddress(partIndex: 0, staffIndexInPart: 1)

        /// Two staves, one 4/4 bar of quarters, so beat `n` is element `n + 1` behind the time signature.
        private static func score() -> Score {
            let staves = [top, bottom].map { address in
                var elements: [VoiceElement] = (0 ..< 4).map { beat in
                    let pitch = 60 + beat + address.staffIndexInPart
                    return .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
                }
                elements.insert(.timeSignature(TimeSignature(numerator: 4, denominator: 4)), at: 0)
                return Staff(measures: [Measure(voices: [Voice(elements: elements)])])
            }
            func text(
                _ value: String, beat: Int, staff: StaffAddress?, system: Bool = false,
            ) -> PositionedSystemElement {
                PositionedSystemElement(
                    position: MeasurePosition(numerator: beat, denominator: 4),
                    element: .staffText(StaffText(text: value, isSystemText: system)), originalStaff: staff,
                )
            }
            return Score(
                division: 480,
                parts: [Part(id: "P1", instrument: Instrument(id: "piano"), staves: IdentifiedArray(staves))],
                systemMeasures: [SystemMeasure(elements: [
                    text("pizz.", beat: 1, staff: top),
                    text("Allegro", beat: 0, staff: nil, system: true),
                    text("arco", beat: 2, staff: bottom),
                    text("espress.", beat: 3, staff: top),
                ])],
            )
        }

        private static func head(_ staff: StaffAddress, beat: Int) -> ScoreItemID {
            .note(NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: beat + 1, noteIndexInChord: 0))
        }

        private static func slot(_ staff: StaffAddress, beat: Int) -> VoiceElementID {
            VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: beat + 1)
        }

        @available(macOS 15.0, *)
        @Test("a range turns its staff and system texts blue, and only those")
        func rangeTintsItsTexts() throws {
            _ = BravuraFont.register
            let score = Self.score()
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
            var items: [ScoreItemID: [CAShapeLayer]] = [:]
            var textItems: Set<ScoreItemID> = []
            for system in document.systems {
                items.merge(ScoreLayerBuilder.buildSystemWithItems(system, metrics: document.metrics).items) { $0 + $1 }
                textItems.formUnion(system.measures.flatMap(\.elements).compactMap(\.textItemID))
            }
            #expect(textItems.count == 4, "the fixture's four texts must all be laid out and selectable")

            // The top staff's first three beats: carries "pizz." and the system text "Allegro", not the bottom
            // staff's "arco", and not "espress.", which starts where the range ends.
            let selection = ScoreSelection.range(
                anchor: Self.head(Self.top, beat: 0), target: Self.head(Self.top, beat: 2),
            )
            let state = SelectionRenderState.make(selection: selection, voiceColors: [0: .blue], score: score)
            ScoreLayerBuilder.applySelection(items: items, previousSelection: .empty, newSelection: state)
            let blue = try #require(state.voiceColors[0])

            let carried: Set<ScoreItemID> = [
                .text(.staffText(anchor: Self.slot(Self.top, beat: 1), style: .staffText)),
                .text(.staffText(anchor: Self.slot(Self.top, beat: 0), style: .systemText)),
            ]
            #expect(carried.isSubset(of: textItems), "the range must name its texts the way the layout names them")
            for item in textItems {
                let layers = try #require(items[item], "every laid-out text has layers to tint")
                let tinted = layers.allSatisfy { $0.fillColor == blue }
                #expect(tinted == carried.contains(item), "\(item) tinted: \(tinted)")
            }

            // And deselecting puts every text back in its own ink.
            ScoreLayerBuilder.applySelection(items: items, previousSelection: state, newSelection: .empty)
            for item in carried {
                #expect(try #require(items[item]).allSatisfy { $0.fillColor != blue })
            }
        }
    }
#endif
