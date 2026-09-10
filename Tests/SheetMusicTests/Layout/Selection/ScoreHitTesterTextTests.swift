#if os(macOS)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Hit-testing the four engraved text kinds.
    ///
    /// ## How the probe points are anchored
    ///
    /// Every point below is built from an origin the DOCUMENT reports — `lyricEntryOrigin`,
    /// `staffTextOrigin`, `harmonyOrigin`, `rehearsalMarkTextOrigin` — never from the box the hit tester
    /// measures. A test that computed its point from the same measurement it is checking would pass for any
    /// tolerance, including a wrong one.
    ///
    /// The offset added to that origin is 2 points, and it is inside the ink for a reason rather than by
    /// luck: at the default `staffSize: 28` one spatium is 7 pt, so a spatium-dependent 10 pt Edwin row sets
    /// at 14 pt. A two- or three-character run is then at least ~14 pt wide and ~14 pt tall, i.e. at least 7
    /// pt of box on each side of a centred origin and 14 pt below a `.bottomLeading` one. 2 pt clears no
    /// edge by accident.
    @Suite("ScoreHitTester — engraved text")
    struct ScoreHitTesterTextTests {
        private let _installApple = TestSupport.installApple

        /// Element index 1 of bar 0 — the first of the fixture's two C4 quarters.
        private static let anchor = VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        @available(macOS 15.0, *)
        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 600,
            )
        }

        // MARK: - Lyrics

        @Test("A point on an engraved syllable reports the lyric, its chord and its verse")
        func lyricIsHit() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let origin = try #require(doc.lyricEntryOrigin(
                at: LyricInputPlanner.Cursor(location: Self.anchor, verse: 0),
            ))
            let tester = ScoreHitTester(document: doc)

            // A syllable is drawn centred on this origin, so a couple of points right of and above it is
            // inside the glyph box.
            #expect(
                tester.hitTest(at: CGPoint(x: origin.x + 2, y: origin.y - 2))
                    == .lyric(anchor: Self.anchor, verse: 0),
            )
        }

        /// The notehead wins a point that BOTH passes claim.
        ///
        /// The earlier version of this test probed `chordStemOrigin` — the staff mid-line, nowhere near the
        /// lyric line — and asserted only "not a lyric", which passes for `nil`, for `.note`, for anything.
        /// It kept passing with the text pass moved to the FIRST rung, i.e. it verified nothing.
        ///
        /// The overlap is built here rather than borrowed from a laid-out score, because **a laid-out score
        /// does not have one** — see `autoplaceKeepsLyricsClearOfTheLadderToday`, which measures that. The
        /// ordering rule is a property of the tester, not of the engine's spacing, so it is tested at that
        /// level: a notehead and a syllable are placed 12 pt apart, closer than autoplace would ever leave
        /// them, and the point between them is asserted to be claimed by `hitText` AND awarded to `.note` by
        /// the full ladder. The first expectation is what makes the second mean something; move the text
        /// pass earlier and the second fails.
        @Test("The notehead wins a point the text pass also claims — text is tried after the ladder")
        func noteheadStillWinsOverText() {
            guard #available(macOS 15.0, *) else { return }
            let sp: CGFloat = 7 // staffSize 28
            let head = CGPoint(x: 100, y: 50)
            let noteID = NoteID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            )
            // Notehead hit circle: radius 1.2 sp = 8.4 pt → y ∈ [41.6, 58.4].
            // Syllable box: half-height 1 sp + 0.25 sp tolerance = 8.75 pt → y ∈ [53.25, 70.75].
            // Contested band: y ∈ [53.25, 58.4].
            let elements: [LayoutElement] = [
                .chord(
                    notes: [LayoutChordNote(
                        noteID: noteID, step: -6, accidental: nil, origin: head,
                        tieForward: nil, tieBack: nil, hasGlissando: false,
                    )],
                    duration: .quarter, stem: .up,
                    stemOrigin: CGPoint(x: head.x, y: head.y - sp * 3.5),
                    hasArpeggio: false, arpeggioRawType: nil, isBeamed: false,
                    voiceIndex: 0, stemExtension: 0, stemIsInvisible: false, mag: 1,
                ),
                .textMark(
                    kind: .lyrics(color: nil, verse: 0, anchor: Self.anchor),
                    text: "glo", origin: CGPoint(x: head.x, y: head.y + 12),
                ),
            ]
            let probe = CGPoint(x: head.x, y: 56)
            let (doc, measure) = Self.syntheticDocument(elements: elements)
            let tester = ScoreHitTester(document: doc)

            #expect(
                tester.hitText(measure: measure, base: .zero, point: probe, sp: sp)
                    == .lyric(anchor: Self.anchor, verse: 0),
                "probe is not inside the syllable's box, so this would prove nothing about ordering",
            )
            #expect(tester.hitTest(at: probe) == .note(noteID))
        }

        /// Autoplace currently keeps the two passes from ever contesting a point in a real layout.
        ///
        /// Measured while writing `noteheadStillWinsOverText`, because the assumption behind it — "a low
        /// notehead's hit circle reaches into the first verse's line" — turned out to be false. The skyline
        /// leaves the lyric line a constant 2.6 sp below the lowest notehead at every pitch and staff size
        /// tried, against a combined reach of 1.2 sp (notehead radius) + 1 sp (half box) + 0.25 sp
        /// (tolerance) = 2.45 sp. It clears by 0.15 sp; the stem-down case clears by 0.1 sp.
        ///
        /// So the ladder ordering is defence-in-depth today, not a rule anything currently exercises. This
        /// test pins the weaker, durable half of that — the boxes are disjoint — without pinning the margin,
        /// which any legitimate engraving change may move.
        @Test("Autoplace keeps a syllable's box clear of the ladder's geometry, so far")
        func autoplaceKeepsLyricsClearOfTheLadderToday() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let lyric = try #require(doc.lyricEntryOrigin(
                at: LyricInputPlanner.Cursor(location: Self.anchor, verse: 0),
            ))
            let tester = ScoreHitTester(document: doc)
            // The syllable's own centre belongs to the syllable, and the notehead's own centre is not
            // inside the syllable's box at all.
            #expect(tester.hitTest(at: lyric) == .lyric(anchor: Self.anchor, verse: 0))
            for system in doc.systems {
                for measure in system.measures {
                    let base = CGPoint(
                        x: system.origin.x + measure.origin.x,
                        y: system.origin.y + measure.origin.y,
                    )
                    for element in measure.elements {
                        guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element,
                              let note = notes.first,
                              note.noteID.elementIndex == Self.anchor.elementIndex
                        else { continue }
                        let head = CGPoint(
                            x: base.x + note.origin.x, y: base.y + note.origin.y,
                        )
                        #expect(tester.hitTest(at: head) == .note(note.noteID))
                        #expect(tester.hitText(
                            measure: measure, base: base, point: head, sp: system.sp,
                        ) == nil)
                    }
                }
            }
        }

        @Test("Empty space below the staff reports nothing rather than the nearest syllable")
        func emptySpaceIsNotAText() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let origin = try #require(doc.lyricEntryOrigin(
                at: LyricInputPlanner.Cursor(location: Self.anchor, verse: 0),
            ))
            let tester = ScoreHitTester(document: doc)
            #expect(tester.hitTest(at: CGPoint(x: origin.x, y: origin.y + 200)) == nil)
        }

        @Test("A point beside a syllable, on the same line, is not the syllable")
        func besideASyllableIsNotAText() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let origin = try #require(doc.lyricEntryOrigin(
                at: LyricInputPlanner.Cursor(location: Self.anchor, verse: 0),
            ))
            let tester = ScoreHitTester(document: doc)
            // 200 pt to the left is still on the lyric line but far outside the one syllable's box, and no
            // other syllable is engraved — a hit here would mean the pass answers by proximity.
            #expect(tester.hitTest(at: CGPoint(x: origin.x - 200, y: origin.y)) == nil)
        }

        // MARK: - Staff text

        @Test("A point on a staff text reports its anchor and its style")
        func staffTextIsHit() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetStaffText(
                anchor: Self.anchor, text: "solo", isSystemText: false,
            ).apply(to: &score)

            let doc = layout(score)
            let origin = try #require(doc.staffTextOrigin(at: Self.anchor, style: .staffText))
            let tester = ScoreHitTester(document: doc)
            // Staff text is drawn `.bottomLeading`, so its ink is to the right of and above this origin.
            #expect(
                tester.hitTest(at: CGPoint(x: origin.x + 2, y: origin.y - 2))
                    == .staffText(anchor: Self.anchor, style: .staffText),
            )
        }

        @Test("A system text reports its own style, not the staff-text one it shares a layout case with")
        func systemTextCarriesItsStyle() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetStaffText(
                anchor: Self.anchor, text: "Swing", isSystemText: true,
            ).apply(to: &score)

            let doc = layout(score)
            // One part, one staff, so this is the canonical staff — the multi-part limitation Task A3
            // documented on `staffTextOrigin` (a system text is unreachable from a non-canonical staff's
            // anchor) does not bite here.
            let origin = try #require(doc.staffTextOrigin(at: Self.anchor, style: .systemText))
            let tester = ScoreHitTester(document: doc)
            #expect(
                tester.hitTest(at: CGPoint(x: origin.x + 2, y: origin.y - 2))
                    == .staffText(anchor: Self.anchor, style: .systemText),
            )
        }

        // MARK: - What the pass refuses to report

        /// A one-measure, one-system document holding exactly `elements`, at the default `staffSize: 28`
        /// (sp = 7) and with a zero base, so an element's own origin is also its document coordinate.
        ///
        /// Used where the engine's placement is not the subject: pinning which elements the pass refuses
        /// (each needs a layout element in a shape only a particular import produces) and pinning the
        /// ladder ordering (which needs an overlap autoplace never leaves). Boxes are still measured from
        /// the elements exactly as in a real document — only where they sit is chosen here.
        @available(macOS 15.0, *)
        private static func syntheticDocument(
            elements: [LayoutElement],
        ) -> (LayoutDocument, LayoutMeasure) {
            let metrics = StaffMetrics(staffSize: 28)
            let measure = LayoutMeasure(
                measureIndex: 0, origin: .zero, width: 400, elements: elements,
            )
            let system = LayoutSystem(
                origin: .zero, size: CGSize(width: 400, height: 100),
                measures: [measure], staffOrigins: [CGPoint(x: 0, y: 40)],
                staffAddresses: [EditingFixtures.staff0],
                partLabels: [], spanners: [], sp: metrics.sp,
            )
            let doc = LayoutDocument(
                size: CGSize(width: 400, height: 100), systems: [system], metrics: metrics,
            )
            return (doc, measure)
        }

        /// `hitText` alone, against a synthetic measure. A point at an element's own origin is inside every
        /// box below, so the pass declining is the only thing that can make one of these `nil`.
        @available(macOS 15.0, *)
        private func hitText(
            on elements: [LayoutElement], at point: CGPoint,
        ) -> ScoreHitTarget? {
            let (doc, measure) = Self.syntheticDocument(elements: elements)
            return ScoreHitTester(document: doc).hitText(
                measure: measure, base: .zero, point: point, sp: doc.metrics.sp,
            )
        }

        @Test("An instrument-change instruction is not a text target, though it shares the staffText case")
        func instrumentChangeIsNotATarget() {
            guard #available(macOS 15.0, *) else { return }
            let origin = CGPoint(x: 40, y: 20)
            // The baseline's descender band has no ink in this string; probe the rendered letter band.
            let inkPoint = CGPoint(x: 45, y: 13)
            // The control: the same element, same origin, differing only in style, IS reported. Without it
            // a `nil` here would be equally consistent with the probe point missing the box.
            #expect(hitText(on: [.staffText(
                text: "to Accordion", origin: origin, color: nil,
                style: .staffText, anchor: Self.anchor,
            )], at: inkPoint) == .staffText(anchor: Self.anchor, style: .staffText))

            #expect(hitText(on: [.staffText(
                text: "to Accordion", origin: origin, color: nil,
                style: .instrumentChange, anchor: Self.anchor,
            )], at: inkPoint) == nil)
        }

        @Test("Text carrying no identity is skipped rather than reported without one")
        func anchorlessTextIsNotATarget() {
            guard #available(macOS 15.0, *) else { return }
            let origin = CGPoint(x: 40, y: 20)
            // A `<Swing>` marking, and a lane element at a tick no chord starts: both reach the page
            // through `.staffText` with `anchor: nil`, and no text-entry command can address either.
            #expect(hitText(on: [.staffText(
                text: "Swing", origin: origin, color: nil, style: .systemText, anchor: nil,
            )], at: origin) == nil)
            // Same for a syllable whose owning chord could not be recovered.
            #expect(hitText(on: [.textMark(
                kind: .lyrics(color: nil, verse: 0, anchor: nil), text: "glo", origin: origin,
            )], at: origin) == nil)
        }

        // MARK: - Chord symbol

        @Test("A point on a chord symbol reports the chord it names")
        func harmonyIsHit() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetChordSymbol(at: Self.anchor, name: "Am7").apply(to: &score)
            // A chord symbol is its own voice element, spliced in immediately BEFORE the chord it names
            // (`AdjacentElementSlot`), so the chord that was at index 1 is at index 2 afterwards — and that
            // shifted index is the anchor `LayoutHarmony` carries.
            let named = VoiceElementID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: 2,
            )

            let doc = layout(score)
            let origin = try #require(doc.harmonyOrigin(at: named))
            let tester = ScoreHitTester(document: doc)
            // A harmony's origin is its leading edge, vertically centred on the run.
            #expect(
                tester.hitTest(at: CGPoint(x: origin.x + 2, y: origin.y))
                    == .harmony(anchor: named),
            )
        }

        // MARK: - Rehearsal mark

        @Test("A point on a rehearsal mark reports its bar")
        func rehearsalMarkIsHit() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)

            let doc = layout(score)
            let origin = try #require(doc.rehearsalMarkTextOrigin(at: Self.anchor))
            let tester = ScoreHitTester(document: doc)
            // `rehearsalMarkTextOrigin` is the frame-inset, bottom-leading origin of the text itself.
            #expect(
                tester.hitTest(at: CGPoint(x: origin.x + 2, y: origin.y - 2))
                    == .rehearsalMark(measureIndex: 0),
            )
        }

        // MARK: - The editing selection ladder must ignore all of it

        @Test("Clicking a lyric does not move the note selection")
        func lyricDoesNotSelectItsNote() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let origin = try #require(doc.lyricEntryOrigin(
                at: LyricInputPlanner.Cursor(location: Self.anchor, verse: 0),
            ))
            // Far enough below the staff that the near-miss rescue box (22 pt) cannot reach a notehead
            // either, so a non-nil answer could only have come from the text target.
            let point = CGPoint(x: origin.x + 2, y: origin.y - 2)
            #expect(ScoreHitTester(document: doc).hitTest(at: point) != nil)
            #expect(doc.editingHitTest(at: point, activeVoice: 0) == nil)
        }
    }
#endif
