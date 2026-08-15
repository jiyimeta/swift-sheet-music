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

        /// The same shape as `singleVoiceSample` on a staff that draws `lineCount` lines, and pitched at the treble
        /// staff's top line (F5, `step` 4) — which is fixed for every line count, so the note itself doesn't move
        /// between the arguments and only the band under test does.
        private func percussionSample(lineCount: Int) -> Score {
            let measure = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 77, tpc: 13)])),
                ]),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "perc"),
                    staves: [Staff(lineCount: lineCount, measures: [measure])],
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

        /// The band is the staff's own barline span with 1 sp clear on each side, so it tracks the staff the caret is
        /// actually in: 6 sp at five lines (as above), 4 sp at three, and — a one-line staff having zero height of
        /// its own — the ±2 sp MuseScore gives its barline, which keeps the caret a column rather than a sliver.
        ///
        /// Three lines is what discriminates a per-staff span from the score-global `StaffMetrics.staffHeight` the
        /// band used to be measured with: it is the only count where the answer is neither the five-line height nor
        /// the one-line special case. One line pins the CENTERING, which a height-only check can't see — measured
        /// from `staffHeight` the band was the right 6 sp there but hung 2 sp too low, straddling nothing.
        @Test(
            "The band spans the staff's own barline span, one sp clear on each side",
            arguments: [(lineCount: 5, top: -1.0, height: 6.0), (3, -1.0, 4.0), (1, -3.0, 6.0)],
        )
        func bandFollowsLineCount(lineCount: Int, top: Double, height: Double) throws {
            let score = percussionSample(lineCount: lineCount)
            let doc = layout(score)
            let item = noteItem()
            let system = try #require(doc.systems.first)
            let flatIndex = try #require(system.flatIndex(for: item.staff))
            let sp = doc.metrics.sp
            let staffTop = system.origin.y + system.staffOrigins[flatIndex].y

            let rect = try #require(doc.editingCaretRect(for: item, in: score))

            #expect(abs(rect.minY - (staffTop + CGFloat(top) * sp)) < 0.001)
            #expect(abs(rect.height - CGFloat(height) * sp) < 0.001)
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

        /// The brief's *other* nil cause: an item that "names a staff/measure this document doesn't contain."
        /// `missingMeasureReturnsNil` above covers the measure half by tripping `staffBand`'s system lookup, which
        /// makes `cursorFrame` refuse too (no system contains that measure). This test covers the staff half — and
        /// that guard, `LayoutSystem.flatIndex(for:)`, can't be tripped through `LayoutEngine` output: within one
        /// `buildSystem` call `elements` and `staffAddresses` are both built from the same `allStaves` list
        /// (`LayoutEngine+SystemBuild.swift:20-21`, element tagging at `:256`, `staffOrigins` at `:592-604`, and
        /// `staffAddresses: allStaves.map(\.address)` at `:920`), and this engine has no per-system staff-subsetting
        /// feature — so every staff `cursorFrame` can find a laid-out element for is, by construction, already in
        /// that system's `staffAddresses`.
        ///
        /// `LayoutSystem`'s own initializer doesn't enforce that invariant, though — `elements`, `staffOrigins` and
        /// `staffAddresses` are three independent arrays with no cross-check between them. So this test hand-builds
        /// a `LayoutSystem` where a rest's `RestID.staff` is real in `elements` but missing from `staffAddresses`: a
        /// legal value of the type that `LayoutEngine` just never happens to produce today. It exists to test THAT
        /// type-level invariant, not anything `LayoutEngine` itself can be driven to emit.
        ///
        /// The guard earns its keep despite being unreachable through `LayoutEngine` today: hiding an instrument's
        /// empty staff on a per-system basis is a real MuseScore convention this engine hasn't implemented yet, and
        /// the day it is, a desynced `LayoutSystem` becomes a live possibility rather than a hypothetical one — at
        /// which point this guard is what stops the caret from silently drawing on the wrong staff.
        @Test("A staff real in elements but absent from a hand-built system's staffAddresses returns nil")
        func staffAbsentFromDesyncedSystemReturnsNil() {
            let presentStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            let absentStaff = StaffAddress(partIndex: 0, staffIndexInPart: 1) // real in `elements`, missing below

            let restID = RestID(staff: absentStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
            let measure = LayoutMeasure(
                measureIndex: 0, origin: .zero, width: 100,
                elements: [.rest(
                    duration: .quarter, origin: CGPoint(x: 10, y: 0), voiceIndex: 0,
                    restID: restID, hasLegerLine: false,
                )],
            )
            let system = LayoutSystem(
                origin: .zero, size: CGSize(width: 100, height: 100), measures: [measure],
                staffOrigins: [CGPoint(x: 0, y: 0)], // only ONE staff's origin
                staffAddresses: [presentStaff], // `absentStaff` is missing even though its rest is in `elements`
                partLabels: [], spanners: [], sp: 7,
            )
            let doc = LayoutDocument(
                size: CGSize(width: 100, height: 100), systems: [system], metrics: StaffMetrics(staffSize: 28),
            )
            let item = ScoreItemID.rest(restID)
            let score = Score(division: 480, parts: [])

            // Precondition: cursorFrame must resolve on its own (exact RestID match against `elements`, independent
            // of `staffAddresses`) — otherwise a nil below would just be missingMeasureReturnsNil's guard firing
            // under a different name, not this one.
            #expect(doc.cursorFrame(for: .item(item), in: score) != nil)

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
