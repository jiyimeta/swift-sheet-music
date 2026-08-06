#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutDocument editingCaretRect")
    struct LayoutDocumentCaretRectTests {
        private let _installApple = TestSupport.installApple

        /// One voice: a G clef and a single quarter chord — enough surface to locate the item's laid-out frame and
        /// its staff band.
        private func singleVoiceSample() -> Score {
            let measure = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                ]),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(
                        staffType: "stdNormal",
                        group: "pitched",
                        defaultClefType: "G",
                        measures: [measure],
                    )],
                )],
            )
        }

        private func layout(_ score: Score, staffSize: CGFloat = 28) -> LayoutDocument {
            var options = ScoreViewOptions()
            options.staffSize = staffSize
            return LayoutEngine.layout(score: score, options: options, availableWidth: 600)
        }

        /// The `ScoreItemID` for the sample's one note: staff 0, measure 0, voice 0, element 1 (after the clef),
        /// note 0 in the chord.
        private func noteItem() -> ScoreItemID {
            .note(NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            ))
        }

        @Test("The rect's top sits one sp above the item's staff top, with a 6 sp height")
        func narrowsToStaffBand() throws {
            let score = singleVoiceSample()
            let doc = layout(score)
            let item = noteItem()
            let system = try #require(doc.systems.first)
            let flatIndex = try #require(system.flatIndex(for: item.staff))
            let sp = doc.metrics.sp
            let staffTop = system.origin.y + system.staffOrigins[flatIndex].y

            let rect = try #require(doc.editingCaretRect(for: item, in: score))

            #expect(rect.minY == staffTop - sp)
            #expect(rect.height == 6 * sp)
        }

        @Test("The rect's X range matches the engine's cursor frame")
        func matchesCursorFrameX() throws {
            let score = singleVoiceSample()
            let doc = layout(score)
            let item = noteItem()
            let frame = try #require(doc.cursorFrame(for: .item(item), in: score))
            // The default minimum width (2) must not be the binding constraint here, or this test would only be
            // checking the floor rather than the frame's own X range.
            #expect(frame.width >= 2)

            let rect = try #require(doc.editingCaretRect(for: item, in: score))

            #expect(rect.minX == frame.minX)
            #expect(rect.maxX == frame.maxX)
        }

        @Test("An item on a measure the document doesn't contain returns nil")
        func missingMeasureReturnsNil() {
            let score = singleVoiceSample()
            let doc = layout(score)
            let item = ScoreItemID.note(NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 99, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
            ))

            #expect(doc.editingCaretRect(for: item, in: score) == nil)
        }

        @Test("minimumWidth floors the returned rect's width when it exceeds the frame's own width")
        func minimumWidthFloorsNarrowFrame() throws {
            let score = singleVoiceSample()
            let doc = layout(score)
            let item = noteItem()
            let frame = try #require(doc.cursorFrame(for: .item(item), in: score))
            let floor: CGFloat = frame.width + 50 // deliberately wider than the frame itself

            let rect = try #require(doc.editingCaretRect(for: item, in: score, minimumWidth: floor))

            #expect(rect.width == floor)
        }
    }
#endif
