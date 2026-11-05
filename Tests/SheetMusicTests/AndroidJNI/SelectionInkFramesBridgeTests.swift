#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        @testable import SheetMusicCore
        import SheetMusicEditWire
        @testable import SheetMusicLayout
        import Testing

        /// `nativeSelectionInkFrames` — where a selected clef or engraved element is drawn, so an Android host can hang
        /// a control off the glyph the reader selected. Each frame is `ScoreHitTester.clefHitRects(for:)` or
        /// `elementHitRects(for:)` on the cached document, the geometry an Apple host floats its controls by, converted
        /// to millimetres; the verb adds the re-addressing `nativeEditingCaretFrame` gives the same item bytes.
        @Suite("Selection ink frames bridge")
        struct SelectionInkFramesBridgeTests {
            private let _installApple = TestSupport.installApple

            private static let ptToMm = 25.4 / 72.0
            private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            private static let staff1 = StaffAddress(partIndex: 0, staffIndexInPart: 1)

            /// The slot the hairpin of `twoSystemScore(hairpin: true)` occupies in bar 0 — what its
            /// `ScoreElementID.spanner` names, as `RemoveSpanner` addresses it.
            private static let hairpinSlot = VoiceElementID(
                staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
            )

            /// One part of `staffCount` staves, two bars of a whole note each, with a line break after the first bar —
            /// exactly two systems whatever the page width. With `hairpin`, staff 0's bar 0 opens a hairpin that ends
            /// with bar 1's note, so its wedge is drawn once on each system.
            private static func twoSystemScore(staffCount: Int = 1, hairpin: Bool = false) -> Score {
                func staff(withHairpin: Bool) -> Staff {
                    var first: [VoiceElement] = [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                    if withHairpin {
                        first.append(.spanner(Spanner(kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 2)))
                    }
                    first.append(.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])))
                    return Staff(measures: [
                        Measure(voices: [Voice(elements: first)], lineBreak: true),
                        Measure(voices: [Voice(elements: [
                            .chord(Chord(duration: .whole, notes: [Note(pitch: 62, tpc: 16)])),
                        ])]),
                    ])
                }
                let staves = (0 ..< staffCount).map { staff(withHairpin: hairpin && $0 == 0) }
                return Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: IdentifiedArray(staves))],
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

            private static func frames(_ handle: Int64, item: ScoreItemID) throws -> SelectionInkFramesWire {
                try SelectionInkFramesCodec.decode(
                    nativeSelectionInkFrames(scoreHandle: handle, itemBytes: ScoreItemIDCodec.encode(item)),
                )
            }

            /// A frame must be `rect`, a document-point rect from the hit tester, in millimetres.
            private static func expectMatches(_ frame: SelectionInkFrameWire, _ rect: CGRect) {
                #expect(abs(frame.xMm - Double(rect.minX) * ptToMm) < 1e-9)
                #expect(abs(frame.yMm - Double(rect.minY) * ptToMm) < 1e-9)
                #expect(abs(frame.widthMm - Double(rect.width) * ptToMm) < 1e-9)
                #expect(abs(frame.heightMm - Double(rect.height) * ptToMm) < 1e-9)
            }

            /// The restatement names the clef the SECOND system opens with, so its one frame lies below the first
            /// system: a frame for the declaration it redraws would sit on the first.
            @Test func `a restated clef answers the glyph on its own system`() throws {
                guard #available(macOS 15.0, *) else { return }
                let handle = Self.laidOut(Self.twoSystemScore())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                #expect(document.systems.count == 2)
                let first = try #require(document.systems.first)
                let anchor = ClefAnchor.restatement(staff: Self.staff0, measureIndex: 1)

                let wire = try Self.frames(handle, item: .clef(anchor))

                #expect(wire.frames.count == 1)
                let frame = try #require(wire.frames.first)
                #expect(frame.yMm > Double(first.origin.y + first.size.height) * Self.ptToMm)
                let rect = try #require(ScoreHitTester(document: document).clefHitRects(for: anchor).first)
                Self.expectMatches(frame, rect)
            }

            /// A hairpin crossing the line break is drawn as one wedge per system: the answer is both pieces, not
            /// their union, which would span the gap between the systems.
            @Test func `an element drawn in two places answers both`() throws {
                guard #available(macOS 15.0, *) else { return }
                let handle = Self.laidOut(Self.twoSystemScore(hairpin: true))
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                #expect(document.systems.count == 2)
                let id = ScoreElementID.spanner(anchor: Self.hairpinSlot, kind: .hairpin)
                let rects = ScoreHitTester(document: document).elementHitRects(for: ScoreHitTarget(elementID: id))

                let wire = try Self.frames(handle, item: .element(id))

                #expect(wire.frames.count == 2)
                #expect(wire.frames.count == rects.count)
                for (frame, rect) in zip(wire.frames, rects) {
                    Self.expectMatches(frame, rect)
                }
            }

            @Test func `a barline answers its stroke and the staff space`() throws {
                let handle = Self.laidOut(Self.twoSystemScore())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)

                let wire = try Self.frames(handle, item: .element(.barLine(measureIndex: 0, role: .trailing)))

                #expect(wire.frames.count == 1)
                let frame = try #require(wire.frames.first)
                #expect(frame.widthMm > 0)
                #expect(frame.widthMm <= 1)
                #expect(abs(wire.spMm - Double(document.metrics.sp) * Self.ptToMm) < 1e-9)
            }

            @Test func `a note answers nothing`() {
                let handle = Self.laidOut(Self.twoSystemScore())
                defer { Self.release(handle) }
                let note = ScoreItemID.note(NoteID(
                    staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
                ))
                let clef = ScoreItemIDCodec.encode(.clef(.restatement(staff: Self.staff0, measureIndex: 1)))

                #expect(nativeSelectionInkFrames(scoreHandle: handle, itemBytes: ScoreItemIDCodec.encode(note)).isEmpty)
                #expect(nativeSelectionInkFrames(scoreHandle: 987_654, itemBytes: clef).isEmpty)
            }

            /// The item bytes name staves in full-score addressing, as `nativeEditingCaretFrame`'s do. With staff 0
            /// hidden, the cached document calls the shown staff (0, 0): staff 1's clef is answered there, and staff
            /// 0's — re-addressed to a `.beat`, since nothing of it is laid out — is answered with nothing.
            @Test func `nothing for undecodable bytes, a hidden staff, or a score never laid out`() throws {
                guard #available(macOS 15.0, *) else { return }
                let handle = Self.laidOut(
                    Self.twoSystemScore(staffCount: 2), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                // Full-score staff 1's clef; and staff 0's, which is the hidden staff's in full-score addressing and
                // the shown staff's in the cached document's.
                let shown = ClefAnchor.restatement(staff: Self.staff1, measureIndex: 1)
                let onStaff0 = ClefAnchor.restatement(staff: Self.staff0, measureIndex: 1)

                let wire = try Self.frames(handle, item: .clef(shown))

                #expect(wire.frames.count == 1)
                let rect = try #require(ScoreHitTester(document: document).clefHitRects(for: onStaff0).first)
                let frame = try #require(wire.frames.first)
                Self.expectMatches(frame, rect)
                #expect(nativeSelectionInkFrames(
                    scoreHandle: handle, itemBytes: ScoreItemIDCodec.encode(.clef(onStaff0)),
                ).isEmpty)
                #expect(nativeSelectionInkFrames(scoreHandle: handle, itemBytes: Data([0xFF, 0xFF, 0xFF])).isEmpty)

                let unlaid = scoreTable.insert(Self.twoSystemScore())
                defer { Self.release(unlaid) }
                #expect(nativeSelectionInkFrames(
                    scoreHandle: unlaid, itemBytes: ScoreItemIDCodec.encode(.clef(onStaff0)),
                ).isEmpty)
            }
        }
    #endif
#endif
