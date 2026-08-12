#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutDocument editingHitTest")
    struct LayoutDocumentEditingHitTestTests {
        private let _installApple = TestSupport.installApple

        /// One voice: a G clef, three quarter chords, and a quarter rest — enough surface for notehead, stem,
        /// margin, and clef cases without a second voice muddying the geometry.
        private func singleVoiceSample() -> Score {
            let chord = { (p: Int) -> VoiceElement in
                .chord(Chord(duration: .quarter, notes: [Note(pitch: p, tpc: 14)]))
            }
            let measure = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    chord(60), .rest(duration: .quarter),
                    chord(64), chord(65),
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

        /// Two voices sharing one measure: voice 0 is four quarter rests, voice 1 is a single whole note. The whole
        /// note's centered position lands close to one of voice 0's individual quarter rests — close enough that
        /// the two fall inside each other's slop box even though they're on different beats.
        private func twoVoiceSample() -> Score {
            let measure = Measure(voices: [
                Voice(elements: [
                    .rest(duration: .quarter), .rest(duration: .quarter),
                    .rest(duration: .quarter), .rest(duration: .quarter),
                ]),
                Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)])),
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

        /// One voice: a G clef followed by a single high note (several diatonic steps above the staff's top line) —
        /// built to probe the on-staff gate, which needs a selectable item that sits *above* the staff band but
        /// still close enough to fall inside a slop box centered just outside that band.
        private func sampleWithNoteAboveStaff() -> Score {
            let measure = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 84, tpc: 14)])),
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

        /// One voice on a staff that draws `lineCount` lines: a G clef and a whole note BELOW the staff (E4, `step`
        /// −4, where a five-line staff's bottom line would be). The mirror of `sampleWithNoteAboveStaff`, for probing
        /// the gate's bottom edge — the one that moves with the line count. A whole note so the probe below it can't
        /// land on a stem.
        private func sampleWithNoteBelowStaff(lineCount: Int) -> Score {
            let measure = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 64, tpc: 18)])),
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

        @Test("Tap on a notehead returns .note for that note")
        func hitsNotehead() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(singleVoiceSample())
            let system = try #require(doc.systems.first)

            var target: (point: CGPoint, id: NoteID)?
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = el,
                          let n = notes.first
                    else { continue }
                    let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
                    let mirrorDx = n.mirrorDx(stem: stem, sp: system.sp)
                    target = (CGPoint(x: base.x + n.origin.x + mirrorDx, y: base.y + n.origin.y), n.noteID)
                    break
                }
                if target != nil { break }
            }
            let hit = try #require(target)

            #expect(doc.editingHitTest(at: hit.point, activeVoice: 0) == .note(hit.id))
        }

        @Test("A tap 10 points off a notehead, still on the staff, rescues to it")
        func nearMissRescues() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(singleVoiceSample())
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)

            var target: (point: CGPoint, id: NoteID)?
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = el,
                          let n = notes.first
                    else { continue }
                    let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
                    let mirrorDx = n.mirrorDx(stem: stem, sp: system.sp)
                    target = (CGPoint(x: base.x + n.origin.x + mirrorDx, y: base.y + n.origin.y), n.noteID)
                    break
                }
                if target != nil { break }
            }
            let hit = try #require(target)
            let missed = CGPoint(x: hit.point.x + 10, y: hit.point.y)
            #expect(
                tester.hitTest(at: missed) == nil,
                "point must miss the engine's own ladder for this to be a rescue",
            )

            #expect(doc.editingHitTest(at: missed, activeVoice: 0) == .note(hit.id))
        }

        @Test("A tap in the page margin, well outside every staff band, returns nil")
        func missesInMargin() {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(singleVoiceSample())
            // Far above the system — outside every staff's slop-extended band.
            #expect(doc.editingHitTest(at: CGPoint(x: 0, y: -500), activeVoice: 0) == nil)
        }

        @Test("A tap that hits voice 1's note prefers a voice-0 item in the slop box when that's the active voice")
        func prefersActiveVoiceInSlopBox() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(twoVoiceSample())
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)

            var voice1NoteID: NoteID?
            var voice1Anchor: CGPoint?
            for el in measure.elements {
                guard case let .chord(notes, _, stem, _, _, _, _, voiceIndex, _, _, _) = el,
                      voiceIndex == 1, let n = notes.first
                else { continue }
                let mirrorDx = n.mirrorDx(stem: stem, sp: system.sp)
                voice1NoteID = n.noteID
                voice1Anchor = CGPoint(x: base.x + n.origin.x + mirrorDx, y: base.y + n.origin.y)
            }
            let anchor = try #require(voice1Anchor)
            let noteID = try #require(voice1NoteID)

            // The raw ladder must hit voice 1's note directly at its own anchor.
            #expect(tester.hitTest(at: anchor) == .note(noteID))

            let slop = CGRect(
                x: anchor.x - LayoutDocument.editingSlopHalfExtent,
                y: anchor.y - LayoutDocument.editingSlopHalfExtent,
                width: LayoutDocument.editingSlopHalfExtent * 2,
                height: LayoutDocument.editingSlopHalfExtent * 2,
            )
            let voice0Item = try #require(tester.itemIDs(in: slop).first { $0.voiceIndex == 0 })

            #expect(doc.editingHitTest(at: anchor, activeVoice: 0) == voice0Item)
        }

        @Test("A tap on a stem returns the stem's first notehead")
        func hitsStemFirstNotehead() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(singleVoiceSample())
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
            let sp = system.sp

            var stemPoint: CGPoint?
            var expectedFirstNote: NoteID?
            for el in measure.elements {
                guard case let .chord(notes, _, stem, _, _, _, isBeamed, _, _, _, _) = el,
                      !isBeamed, let first = notes.first
                else { continue }
                let ys = notes.map(\.origin.y)
                guard let minY = ys.min(), let maxY = ys.max() else { continue }
                let stemXOffset = sp * 0.59
                let x: CGFloat
                let y: CGFloat
                if stem == .up {
                    x = base.x + first.origin.x + stemXOffset
                    // Midpoint of the stem's above-notehead span — clear of the notehead's own hit radius.
                    y = base.y + minY - sp * 1.75
                } else {
                    x = base.x + first.origin.x - stemXOffset
                    y = base.y + maxY + sp * 1.75
                }
                stemPoint = CGPoint(x: x, y: y)
                expectedFirstNote = first.noteID
                break
            }
            let point = try #require(stemPoint)
            let expected = try #require(expectedFirstNote)

            // Confirm the point actually lands on the stem (not the notehead) before trusting the assertion below.
            #expect(tester.hitTest(at: point) == .stem(notes: [expected]))

            #expect(doc.editingHitTest(at: point, activeVoice: 0) == .note(expected))
        }

        @Test("A tap on a clef, with no other item nearby, returns nil")
        func missesClef() throws {
            guard #available(macOS 15.0, *) else { return }
            // A bigger staff size widens the header (clef → first note) past the fixed 22-pt slop half-extent, so
            // the rescue this policy performs for a genuine near miss doesn't also catch a clef tap — the clef and
            // the note it precedes must land in two different slop boxes for this to test "clef means nothing"
            // rather than "clef rescues to the note next to it".
            let doc = layout(singleVoiceSample(), staffSize: 120)
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
            let sp = system.sp

            var clefPoint: CGPoint?
            for el in measure.elements {
                guard case let .clef(rawType, origin, anchor) = el, anchor != nil else { continue }
                // Treble clef is drawn 1 sp above its anchor (mirrors `ScoreHitTester.clefYOffset`).
                let yOffset = rawType == "G" ? sp : 0
                clefPoint = CGPoint(x: base.x + origin.x, y: base.y + origin.y + yOffset)
                break
            }
            let point = try #require(clefPoint)

            // Confirm the raw ladder resolves this point to the clef before trusting the assertion below.
            guard case .clef = try #require(tester.hitTest(at: point)) else {
                Issue.record("expected the probe point to land on the clef")
                return
            }
            // And confirm nothing else falls inside the same slop box the rescue would search — otherwise this
            // would just be re-testing the near-miss rescue under a different name.
            let slop = CGRect(
                x: point.x - LayoutDocument.editingSlopHalfExtent, y: point.y - LayoutDocument.editingSlopHalfExtent,
                width: LayoutDocument.editingSlopHalfExtent * 2, height: LayoutDocument.editingSlopHalfExtent * 2,
            )
            #expect(tester.itemIDs(in: slop).isEmpty, "expected no item within the slop box of the clef probe point")

            #expect(doc.editingHitTest(at: point, activeVoice: 0) == nil)
        }

        /// The gate this test exercises has no other coverage: every other test either taps well inside a staff
        /// band, or so far outside (the page-margin test) that the slop box is empty anyway — so a mutant that
        /// deletes `guard isOnStaff(point) else { return nil }`, leaving the near-miss rescue unconditional, passes
        /// every other test in this file unchanged. This is the one built to fail on that mutant: the note above
        /// the staff sits *inside* the probe's slop box (so the rescue has something to return), but the probe
        /// itself sits just outside the on-staff band (so the gate must be the thing that refuses it). With the
        /// gate: `nil`. Without it: the note above the staff.
        @Test("A tap just outside the staff band, even with a note inside its slop box, returns nil")
        func offStaffGateRefusesEvenWhenSlopBoxIsNotEmpty() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(sampleWithNoteAboveStaff())
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
            let staffTop = system.origin.y + system.staffOrigins[0].y

            var noteID: NoteID?
            var noteAnchor: CGPoint?
            for el in measure.elements {
                guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = el, let n = notes.first
                else { continue }
                let mirrorDx = n.mirrorDx(stem: stem, sp: system.sp)
                noteID = n.noteID
                noteAnchor = CGPoint(x: base.x + n.origin.x + mirrorDx, y: base.y + n.origin.y)
            }
            let id = try #require(noteID)
            let anchor = try #require(noteAnchor)
            // The note must actually sit above the staff for this probe to mean anything.
            #expect(anchor.y < staffTop)

            // One point past the gate's own boundary — the tightest honest "outside" — directly above the note so
            // the slop box below still centers on it horizontally.
            let probe = CGPoint(x: anchor.x, y: staffTop - LayoutDocument.editingSlopHalfExtent - 1)

            // The probe itself must miss the raw ladder — this has to be a near-miss case, not an on-target hit.
            #expect(tester.hitTest(at: probe) == nil)

            let slop = CGRect(
                x: probe.x - LayoutDocument.editingSlopHalfExtent, y: probe.y - LayoutDocument.editingSlopHalfExtent,
                width: LayoutDocument.editingSlopHalfExtent * 2, height: LayoutDocument.editingSlopHalfExtent * 2,
            )
            // The rescue has something to find — so a `nil` result below can only be the on-staff gate at work, not
            // an empty slop box.
            #expect(tester.itemIDs(in: slop).contains(.note(id)))

            #expect(doc.editingHitTest(at: probe, activeVoice: 0) == nil)
        }

        /// The gate's bottom edge follows the staff's own line count, not the score-global 4 sp
        /// `StaffMetrics.staffHeight` reports for every staff. Three lines is the discriminating count: the band ends
        /// 2 sp above where the retired rule put it, and since 1.11.0 stacks staves by their own line count, that
        /// overshoot is another staff's paper — a tap there was rescued to a note in THIS staff.
        ///
        /// Built as the mirror of `offStaffGateRefusesEvenWhenSlopBoxIsNotEmpty`: the probe sits one point past the
        /// correct band's bottom edge with the below-staff note inside its slop box, so only the gate can refuse it.
        /// The assertion that the probe is still inside the RETIRED band is what makes this fail on the old rule
        /// rather than merely pass on the new one.
        @Test("A tap below a three-line staff's own band returns nil even with a note in its slop box")
        func offStaffGateBottomEdgeFollowsLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = layout(sampleWithNoteBelowStaff(lineCount: 3))
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
            let sp = system.sp
            let staffTop = system.origin.y + system.staffOrigins[0].y

            var noteID: NoteID?
            var noteAnchor: CGPoint?
            for el in measure.elements {
                guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = el, let n = notes.first
                else { continue }
                noteID = n.noteID
                noteAnchor = CGPoint(
                    x: base.x + n.origin.x + n.mirrorDx(stem: stem, sp: sp), y: base.y + n.origin.y,
                )
            }
            let id = try #require(noteID)
            let anchor = try #require(noteAnchor)

            // Three lines span 2 sp from the top line, so that is where the band ends and the gate's slop begins.
            let bandBottom = staffTop + 2 * sp
            // The note must sit below the band for this probe to mean anything.
            #expect(anchor.y > bandBottom)
            let probe = CGPoint(x: anchor.x, y: bandBottom + LayoutDocument.editingSlopHalfExtent + 1)
            // Still inside the band the retired 4 sp rule drew, so the old code accepts this probe and rescues.
            #expect(probe.y < staffTop + 4 * sp + LayoutDocument.editingSlopHalfExtent)

            // A near miss, not an on-target hit.
            #expect(tester.hitTest(at: probe) == nil)
            let slop = CGRect(
                x: probe.x - LayoutDocument.editingSlopHalfExtent, y: probe.y - LayoutDocument.editingSlopHalfExtent,
                width: LayoutDocument.editingSlopHalfExtent * 2, height: LayoutDocument.editingSlopHalfExtent * 2,
            )
            // The rescue has something to find, so a nil below can only be the gate.
            #expect(tester.itemIDs(in: slop).contains(.note(id)))

            #expect(doc.editingHitTest(at: probe, activeVoice: 0) == nil)
        }
    }
#endif
