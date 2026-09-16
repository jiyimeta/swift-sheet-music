#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import QuartzCore
        import SheetMusicCore
        @testable import SheetMusicLayout
        @testable import SheetMusicUI
        import SwiftUI
        import Testing

        /// The CALayer path registers a grace head under its grace identity, so selecting a grace note tints that
        /// head alone, and selecting its parent note leaves the grace untouched.
        @Suite("ScoreLayerBuilder — grace note tint")
        struct ScoreLayerBuilderGraceTintTests {
            private let _installApple = TestSupport.installApple

            private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            private static let parent = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
            private static let graceItem = ScoreItemID.graceNote(GraceNoteID(
                parent: parent, side: .before, graceIndex: 0, noteIndexInGraceChord: 0,
            ))
            private static let noteItem = ScoreItemID.note(NoteID(
                staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            ))

            /// B4 with a G4 acciaccatura, then a dotted half rest.
            private static func score() -> Score {
                let voice = Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .chord(Chord(
                        duration: .quarter, notes: [Note(pitch: 71, tpc: 19)],
                        graceNotesBefore: [GraceChord(
                            graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 67, tpc: 15)],
                        )],
                        graceNotesAfter: [],
                    )),
                    .rest(duration: .fraction(Fraction(numerator: 3, denominator: 4))),
                ])
                return Score(division: 480, parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )])
            }

            @available(macOS 15.0, *)
            private static func built() throws -> ScoreLayerBuilder.SystemLayers {
                let document = LayoutEngine.layout(score: score(), options: ScoreViewOptions(), availableWidth: 1200)
                let system = try #require(document.systems.first)
                return ScoreLayerBuilder.buildSystemWithItems(system, metrics: document.metrics)
            }

            @Test("A grace head registers under .graceNote, apart from its parent's head")
            func registersByGraceIdentity() throws {
                guard #available(macOS 15.0, *) else { return }
                let built = try Self.built()
                let graceLayers = try #require(built.items[Self.graceItem])
                let noteLayers = try #require(built.items[Self.noteItem])
                #expect(!graceLayers.isEmpty)
                let graceSet = Set(graceLayers.map(ObjectIdentifier.init))
                #expect(graceSet.isDisjoint(with: noteLayers.map(ObjectIdentifier.init)))
                // Nothing is keyed by the grace head's synthetic layout `NoteID` (noteIndexInChord ≥ 1000).
                let synthetic = built.items.keys.filter {
                    if case let .note(id) = $0 { return id.noteIndexInChord >= 1000 }
                    return false
                }
                #expect(synthetic.isEmpty)
            }

            @Test("Selecting the grace tints only the grace; selecting the parent tints only the parent")
            func selectionsAreDisjoint() throws {
                guard #available(macOS 15.0, *) else { return }
                let built = try Self.built()
                let graceLayers = try #require(built.items[Self.graceItem])
                let noteLayers = try #require(built.items[Self.noteItem])
                let graceInk = graceLayers.map(\.fillColor)
                let noteInk = noteLayers.map(\.fillColor)

                let graceSelection = SelectionRenderState.make(
                    selection: .single(Self.graceItem), voiceColors: [0: .red], score: Self.score(),
                )
                let tint = try #require(graceSelection.voiceColors[0])
                ScoreLayerBuilder.applySelection(
                    items: built.items, previousSelection: .empty, newSelection: graceSelection,
                )
                #expect(graceLayers.allSatisfy { $0.fillColor == tint })
                #expect(noteLayers.map(\.fillColor) == noteInk)

                let noteSelection = SelectionRenderState.make(
                    selection: .single(Self.noteItem), voiceColors: [0: .red], score: Self.score(),
                )
                ScoreLayerBuilder.applySelection(
                    items: built.items, previousSelection: graceSelection, newSelection: noteSelection,
                )
                #expect(noteLayers.allSatisfy { $0.fillColor == tint })
                #expect(graceLayers.map(\.fillColor) == graceInk)
            }
        }
    #endif
#endif
