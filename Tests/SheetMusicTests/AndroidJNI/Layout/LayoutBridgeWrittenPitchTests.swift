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

        /// `LayoutOptionsWire.writtenPitch`. When a host asks, the bridge draws each transposing part at the pitch its
        /// player reads, in Apple's order (clef overrides, written pitch, transpose, hidden staves), and every
        /// identity the geometry bridges hand back is still the stored score's. Driven through `nativeComputeLayout`,
        /// the entry point Android calls. Pitches are read back from the cache entry's `filteredScore`, the score the
        /// layout was built from, so they are the pitches drawn.
        @Suite("Layout bridge written pitch")
        struct LayoutBridgeWrittenPitchTests {
            private let _installApple = TestSupport.installApple

            private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            private static let clarinet = StaffAddress(partIndex: 1, staffIndexInPart: 0)

            /// Part 0 is a flute (concert pitch) and part 1 a B♭ clarinet (sounds a major second below written). One G
            /// staff each, C major, one whole note concert B♭4 (pitch 70, tpc 12) at element 2 of bar 1. This is the
            /// shape `WrittenPitchViewTests.ensemble()` uses.
            private static func ensemble() -> Score {
                var score = Score.blank(BlankScoreTemplate(
                    title: "T",
                    parts: [
                        .init(instrumentID: "flute", staves: [.init(clefType: "G")]),
                        .init(
                            instrumentID: "clarinet", staves: [.init(clefType: "G")],
                            transposeDiatonic: -1, transposeChromatic: -2,
                        ),
                    ],
                    measureCount: 1,
                ))
                for partIndex in score.parts.indices {
                    score.parts.updateValue(at: partIndex) { partValue in
                        partValue.staves.updateValue(at: 0) { staffValue in
                            staffValue.measures[0].voices[0].elements.updateValue(at: 2) {
                                $0 = .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
                            }
                        }
                    }
                }
                return score
            }

            private static func note(on staff: StaffAddress) -> NoteID {
                NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0)
            }

            private static func options(
                writtenPitch: UInt8, transpose: Int32 = 0, hidden: [HiddenStaffWire] = [],
            ) -> Data {
                var wire = LayoutOptionsWire.verticalDefault
                wire.writtenPitch = writtenPitch
                wire.transposeSemitones = transpose
                wire.hiddenStaves = hidden
                return wire.encodeToData()
            }

            /// `ensemble()` laid out through the JNI entry point. The caller releases the handle.
            private static func laidOut(_ options: Data) -> Int64 {
                let handle = scoreTable.insert(ensemble())
                _ = nativeComputeLayout(scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: options)
                return handle
            }

            /// The pitch the cached layout drew the note `id` with. `id` is in the FILTERED score's addressing.
            private static func drawnPitch(_ handle: Int64, _ id: NoteID) -> Int? {
                LayoutDocumentCache.entry(for: handle)?.filteredScore[id]?.pitch
            }

            private static func release(_ handle: Int64) {
                scoreTable.release(handle)
                LayoutDocumentCache.release(handle)
            }

            @Test func `a transposing part stays at concert pitch unless the host asks`() {
                let handle = Self.laidOut(Self.options(writtenPitch: 0))
                defer { Self.release(handle) }
                #expect(Self.drawnPitch(handle, Self.note(on: Self.clarinet)) == 70)
            }

            @Test func `asked, the clarinet is drawn a whole tone up and the flute is not`() {
                let handle = Self.laidOut(Self.options(writtenPitch: 1))
                defer { Self.release(handle) }
                #expect(Self.drawnPitch(handle, Self.note(on: Self.clarinet)) == 72)
                #expect(Self.drawnPitch(handle, Self.note(on: Self.flute)) == 70)
            }

            /// The key signature moves with the notes: a C-major concert key reads as written D major.
            @Test func `asked, the clarinet's key signature is the written key`() {
                let handle = Self.laidOut(Self.options(writtenPitch: 1))
                defer { Self.release(handle) }
                let score = LayoutDocumentCache.entry(for: handle)?.filteredScore
                #expect(score?.activeKey(staff: Self.clarinet, measureIndex: 0) == 2)
                #expect(score?.activeKey(staff: Self.flute, measureIndex: 0) == 0)
            }

            /// Written pitch and the global transpose compose: 70 → 72 → 74 for the clarinet, 70 → 72 for the flute.
            /// Pitches cannot pin the ORDER (semitone shifts commute); see Step 6.
            @Test func `the written view and the transpose compose`() {
                let handle = Self.laidOut(Self.options(writtenPitch: 1, transpose: 2))
                defer { Self.release(handle) }
                #expect(Self.drawnPitch(handle, Self.note(on: Self.clarinet)) == 74)
                #expect(Self.drawnPitch(handle, Self.note(on: Self.flute)) == 72)
            }

            /// Hiding the flute renumbers the clarinet to part 0 of the filtered score. The written view ran while it
            /// was still part 1, so the clarinet still reads written.
            @Test func `the written view survives hiding an earlier part`() {
                let handle = Self.laidOut(Self.options(
                    writtenPitch: 1, hidden: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                ))
                defer { Self.release(handle) }
                #expect(Self.drawnPitch(handle, Self.note(on: Self.flute)) == 72)
            }

            /// The view moves pitches, never identities. A tap on the clarinet's notehead still answers the stored
            /// score's `NoteID`, full-score addressed, which is what an edit intent needs.
            @Test @available(macOS 15.0, iOS 16.0, *)
            func `the editing hit test still answers the stored note`() throws {
                let handle = Self.laidOut(Self.options(writtenPitch: 1))
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.value(for: handle))
                let tap = try #require(Self.notehead(of: Self.note(on: Self.clarinet), in: document))
                let ptToMM = 25.4 / 72.0
                let hit = nativeEditingHitTest(
                    scoreHandle: handle, xMm: Double(tap.x) * ptToMM, yMm: Double(tap.y) * ptToMM, activeVoice: 0,
                )
                #expect(try ScoreItemIDCodec.decode(hit) == .note(Self.note(on: Self.clarinet)))
            }

            /// Document-space centre of the notehead `id`, found the way `ScoreHitTester` scans the layout.
            private static func notehead(of id: NoteID, in document: LayoutDocument) -> CGPoint? {
                for system in document.systems {
                    for measure in system.measures {
                        for element in measure.elements {
                            guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = element,
                                  let note = notes.first(where: { $0.noteID == id })
                            else { continue }
                            let dx = note.mirrorDx(stem: stem, sp: system.sp)
                            return CGPoint(
                                x: system.origin.x + measure.origin.x + note.origin.x + dx,
                                y: system.origin.y + measure.origin.y + note.origin.y,
                            )
                        }
                    }
                }
                return nil
            }
        }
    #endif
#endif
