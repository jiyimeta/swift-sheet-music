#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        @testable import SheetMusicCore
        import SheetMusicEditWire
        @testable import SheetMusicLayout
        import Testing

        /// `nativeRangeBoxFrames` — the outline a range selection draws. Each frame is
        /// `LayoutSystem.rangeBoxRect(selectedIDs:metrics:)`, the one implementation an Apple host strokes too,
        /// moved by its system's origin into document coordinates and converted to millimetres; the verb adds the
        /// re-addressing and expansion `nativeEncodeDrawProgram` gives the same payload.
        @Suite("Range box frames bridge")
        struct RangeBoxFramesBridgeTests {
            private let _installApple = TestSupport.installApple

            private static let ptToMm = 25.4 / 72.0
            private static let tintArgb: UInt32 = 0xFFAB_CDEF

            /// One part, two staves, two bars of a whole C4 on each, with a line break after the first bar — exactly
            /// two systems whatever the page width.
            private static func twoSystemScore() -> Score {
                func staff() -> Staff {
                    Staff(measures: [
                        Measure(
                            voices: [Voice(elements: [
                                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                                .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                            ])],
                            lineBreak: true,
                        ),
                        Measure(voices: [Voice(elements: [
                            .chord(Chord(duration: .whole, notes: [Note(pitch: 62, tpc: 16)])),
                        ])]),
                    ])
                }
                return Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff(), staff()])],
                )
            }

            /// The whole note of `measure` on staff `(0, staffIndex)` of `twoSystemScore()`.
            private static func note(staff staffIndex: Int, measure: Int) -> ScoreItemID {
                .note(NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: staffIndex),
                    measureIndex: measure,
                    voiceIndex: 0,
                    elementIndex: measure == 0 ? 1 : 0,
                    noteIndexInChord: 0,
                ))
            }

            /// One measure, 4/4: a triplet of quarter-time chords followed by three quarter rests — the shape
            /// `EditGeometryBridgeTests.tripletScore()` tints.
            private static func tripletScore() -> Score {
                let third = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
                let voice = Voice(
                    elements: [
                        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                        .chord(Chord(duration: third, notes: [Note(pitch: 60, tpc: 14)])),
                        .chord(Chord(duration: third, notes: [Note(pitch: 62, tpc: 16)])),
                        .chord(Chord(duration: third, notes: [Note(pitch: 64, tpc: 18)])),
                        .rest(duration: .quarter),
                        .rest(duration: .quarter),
                        .rest(duration: .quarter),
                    ],
                    tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
                )
                return Score(
                    division: 480,
                    parts: [Part(
                        id: "1", instrument: Instrument(id: "x"),
                        staves: [Staff(measures: [Measure(voices: [voice])])],
                    )],
                )
            }

            private static func laidOut(_ score: Score, hiding hidden: [HiddenStaffWire] = []) -> Int64 {
                let handle = scoreTable.insert(score)
                var wire = LayoutOptionsWire.verticalDefault
                wire.hiddenStaves = hidden
                _ = nativeComputeLayout(
                    scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: wire.encodeToData(),
                )
                return handle
            }

            private static func release(_ handle: Int64) {
                scoreTable.release(handle)
                LayoutDocumentCache.release(handle)
            }

            private static func frames(_ handle: Int64, ids: Set<ScoreItemID>) throws -> RangeBoxFramesWire {
                let bytes = nativeRangeBoxFrames(
                    scoreHandle: handle, selectionBytes: SelectionTintCodec.encode(argb: tintArgb, ids: ids),
                )
                return try RangeBoxFramesCodec.decode(bytes)
            }

            /// What a frame must be: `system`'s own box for `ids` (already in the cached document's addressing), moved
            /// by the system's origin, in millimetres.
            private static func expectMatches(
                _ frame: RangeBoxFrameWire, system: LayoutSystem, ids: Set<ScoreItemID>, metrics: StaffMetrics,
            ) throws {
                let box = try #require(system.rangeBoxRect(selectedIDs: ids, metrics: metrics))
                #expect(abs(frame.xMm - Double(system.origin.x + box.minX) * ptToMm) < 1e-9)
                #expect(abs(frame.yMm - Double(system.origin.y + box.minY) * ptToMm) < 1e-9)
                #expect(abs(frame.widthMm - Double(box.width) * ptToMm) < 1e-9)
                #expect(abs(frame.heightMm - Double(box.height) * ptToMm) < 1e-9)
            }

            /// The second system, so its origin is well below the document's top: a frame left in system coordinates
            /// would sit on the first system instead.
            @Test func `a range on one staff is one frame, its system's box moved by the origin, in mm`() throws {
                let handle = Self.laidOut(Self.twoSystemScore())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                #expect(document.systems.count == 2)
                let system = try #require(document.systems.last)
                #expect(system.origin.y > 0)
                let ids: Set = [Self.note(staff: 0, measure: 1)]

                let wire = try Self.frames(handle, ids: ids)

                #expect(wire.frames.count == 1)
                let frame = try #require(wire.frames.first)
                try Self.expectMatches(frame, system: system, ids: ids, metrics: document.metrics)
                #expect(abs(wire.lineWidthMm - Double(document.metrics.rangeBoxLineWidth) * Self.ptToMm) < 1e-9)
            }

            @Test func `a range across a system break is one frame per system, top to bottom`() throws {
                let handle = Self.laidOut(Self.twoSystemScore())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                #expect(document.systems.count == 2)
                let ids: Set = [
                    Self.note(staff: 0, measure: 0), Self.note(staff: 1, measure: 0),
                    Self.note(staff: 0, measure: 1), Self.note(staff: 1, measure: 1),
                ]

                let wire = try Self.frames(handle, ids: ids)

                #expect(wire.frames.count == 2)
                for (frame, system) in zip(wire.frames, document.systems) {
                    try Self.expectMatches(frame, system: system, ids: ids, metrics: document.metrics)
                }
                let first = try #require(wire.frames.first)
                let second = try #require(wire.frames.last)
                #expect(second.yMm >= first.yMm + first.heightMm)
            }

            /// The payload names staves in full-score addressing, as the tint's does. With staff 0 hidden, the cached
            /// document calls the shown staff (0, 0), and the box is drawn around that.
            @Test func `a selection on a shown staff is re-addressed past the hidden one`() throws {
                let handle = Self.laidOut(
                    Self.twoSystemScore(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let system = try #require(document.systems.last)

                let wire = try Self.frames(handle, ids: [Self.note(staff: 1, measure: 1)])

                #expect(wire.frames.count == 1)
                let frame = try #require(wire.frames.first)
                try Self.expectMatches(
                    frame, system: system, ids: [Self.note(staff: 0, measure: 1)], metrics: document.metrics,
                )
                #expect(nativeRangeBoxFrames(
                    scoreHandle: handle,
                    selectionBytes: SelectionTintCodec.encode(
                        argb: Self.tintArgb, ids: [Self.note(staff: 0, measure: 1)],
                    ),
                ).isEmpty)
            }

            /// A tuplet id names no note itself; expanded as the tint expands it, it covers its three members.
            @Test func `a tuplet is expanded to its members, as the tint is`() throws {
                let handle = Self.laidOut(Self.tripletScore())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let system = try #require(document.systems.first)
                let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
                let tuplet = ScoreItemID.tuplet(TupletID(
                    staff: staff, measureIndex: 0, voiceIndex: 0, startElementIndex: 1,
                ))
                let members = Set((1 ... 3).map { element in
                    ScoreItemID.note(NoteID(
                        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0,
                    ))
                })

                let wire = try Self.frames(handle, ids: [tuplet])

                #expect(wire.frames.count == 1)
                let frame = try #require(wire.frames.first)
                try Self.expectMatches(frame, system: system, ids: members, metrics: document.metrics)
            }

            @Test func `no box for an empty or undecodable selection, an unknown handle, or a score never laid out`() {
                let handle = Self.laidOut(Self.twoSystemScore())
                defer { Self.release(handle) }
                let empty = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [])

                #expect(nativeRangeBoxFrames(scoreHandle: handle, selectionBytes: empty).isEmpty)
                #expect(nativeRangeBoxFrames(scoreHandle: handle, selectionBytes: Data([0xFF, 0xFF, 0xFF])).isEmpty)
                #expect(nativeRangeBoxFrames(scoreHandle: 987_654, selectionBytes: empty).isEmpty)

                let unlaid = scoreTable.insert(Self.twoSystemScore())
                defer { Self.release(unlaid) }
                let selection = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [Self.note(staff: 0, measure: 0)])
                #expect(nativeRangeBoxFrames(scoreHandle: unlaid, selectionBytes: selection).isEmpty)
            }
        }
    #endif
#endif
