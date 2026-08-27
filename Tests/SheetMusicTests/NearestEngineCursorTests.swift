#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Tests for the shared tap→engine-cursor pipeline (`nearestEngineCursor`)
    /// that both iOS and the Android JNI bridge call. Builds a real
    /// `LayoutDocument` via `LayoutEngine.layout` (FontMetrics provider
    /// installed through `TestSupport.installApple`) so the geometry the
    /// hit-tester walks is the production layout, not a fake.
    @Suite("nearestEngineCursor")
    struct NearestEngineCursorTests {
        private let _installApple = TestSupport.installApple

        /// A 2-part × 1-staff score. Each part's first measure holds one
        /// quarter-note chord. Both pitches sit on the treble staff (G4 =
        /// MIDI 67, B4 = MIDI 71) so the targeted notehead falls inside the
        /// `chooseEvent` staff band and a center-tap lands on it.
        private func makeScore() -> Score {
            func part(id: String, pitch: Int) -> Part {
                let chord = Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)])
                let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
                return Part(
                    id: id,
                    instrument: Instrument(id: id, channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [measure])],
                )
            }
            return Score(division: 480, parts: [part(id: "p0", pitch: 67), part(id: "p1", pitch: 71)])
        }

        /// Document-coordinate anchor for the layout chord whose first note
        /// has `noteID`. Reconstructed exactly the way `chooseEvent`
        /// computes its hit anchor (measure base + note origin + mirrorDx),
        /// so a tap here lands dead-center on that note.
        private func anchor(
            for noteID: NoteID, in document: LayoutDocument,
        ) -> CGPoint? {
            for system in document.systems {
                for measure in system.measures {
                    let baseX = system.origin.x + measure.origin.x
                    let baseY = system.origin.y + measure.origin.y
                    for element in measure.elements {
                        guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = element,
                              let first = notes.first, first.noteID == noteID
                        else { continue }
                        return CGPoint(
                            x: baseX + first.origin.x + first.mirrorDx(stem: stem, sp: system.sp),
                            y: baseY + first.origin.y,
                        )
                    }
                }
            }
            return nil
        }

        @Test("tap on a note returns that note")
        func tapOnNoteReturnsNote() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = makeScore()
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let expected = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
            )
            let point = try #require(anchor(for: expected, in: document))
            let cursor = nearestEngineCursor(
                at: point, in: document, score: score, hiddenStaves: [],
            )
            #expect(cursor == .item(.note(expected)))
        }

        @Test("tap with a hidden staff returns a full-score address")
        func tapWithHiddenStaffReturnsFullScoreAddress() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = makeScore()
            // Hide part 0's only staff. After filtering, part 1's staff
            // renumbers to filtered partIndex 0.
            let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
            let filtered = score.filtered(hidingStaves: hidden)
            let document = LayoutEngine.layout(
                score: filtered, options: .init(), availableWidth: 800,
            )
            // The surviving staff is positional index 0 in the filtered layout.
            let filteredNoteID = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
            )
            let point = try #require(anchor(for: filteredNoteID, in: document))
            let cursor = nearestEngineCursor(
                at: point, in: document, score: score, hiddenStaves: hidden,
            )
            guard case let .item(.note(resolved)) = try #require(cursor) else {
                Issue.record("expected a note cursor, got \(String(describing: cursor))")
                return
            }
            // Re-addressed to the FULL-score index (part 1), not the filtered 0.
            #expect(resolved.staff.partIndex == 1)
            #expect(resolved.staff.staffIndexInPart == 0)
            #expect(resolved.measureIndex == 0)
            #expect(resolved.elementIndex == 0)
        }

        @Test("tap on a ledger-line note returns it, not an in-band neighbor")
        func tapOnLedgerLineNoteReturnsIt() throws {
            guard #available(macOS 15.0, *) else { return }
            // One staff, one measure, two quarter-note beats: beat 0 is a very low note that needs ledger lines well
            // below the staff (its notehead sits far outside the 2.5 sp band around the centerline); beat 1 sits near
            // the centerline. Tapping beat 0's notehead must return beat 0 — the old visual-Y staff-membership filter
            // rejected it and snapped to beat 1. This is the hidden-staff tap-to-seek bug in miniature.
            let lowChord = Chord(duration: .quarter, notes: [Note(pitch: 36, tpc: 14)]) // C2, ledger lines below
            let centerChord = Chord(duration: .quarter, notes: [Note(pitch: 71, tpc: 14)]) // B4, ~centerline
            let part = Part(
                id: "p0",
                instrument: Instrument(id: "p0", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [Measure(voices: [
                    Voice(elements: [.chord(lowChord), .chord(centerChord)]),
                ])])],
            )
            let score = Score(division: 480, parts: [part])
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let beat0 = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
            )
            let point = try #require(anchor(for: beat0, in: document))
            let cursor = nearestEngineCursor(
                at: point, in: document, score: score, hiddenStaves: [],
            )
            #expect(cursor == .item(.note(beat0)))
        }

        @Test("tap in empty space returns nil")
        func tapInEmptySpaceReturnsNil() throws {
            guard #available(macOS 15.0, *) else { return }
            // Two parts: part 0 carries a note, part 1's staff has an empty
            // measure (no chord/rest). A tap centered on part 1's staff
            // picks that staff's mid-Y; part 0's note lies outside part 1's
            // band, and part 1 itself has nothing playable → nil.
            let withNote = Part(
                id: "p0",
                instrument: Instrument(id: "p0", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [Measure(voices: [
                    Voice(elements: [.chord(Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 14)]))]),
                ])])],
            )
            let empty = Part(
                id: "p1",
                instrument: Instrument(id: "p1", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let score = Score(division: 480, parts: [withNote, empty])
            let document = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let system = try #require(document.systems.first)
            #expect(system.staffOrigins.count == 2)
            // Mid-Y of part 1's (empty) staff in document coordinates.
            let emptyStaffMidY = system.origin.y + system.staffOrigins[1].y + 2 * system.sp
            let point = CGPoint(
                x: system.origin.x + system.size.width / 2,
                y: emptyStaffMidY,
            )
            let cursor = nearestEngineCursor(
                at: point, in: document, score: score, hiddenStaves: [],
            )
            #expect(cursor == nil)
        }
    }
#endif
