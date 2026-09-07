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

        @Test("The notehead still wins where the two overlap — text is tried after the ladder")
        func noteheadStillWinsOverText() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let head = try #require(doc.chordStemOrigin(at: Self.anchor))
            let tester = ScoreHitTester(document: doc)
            if case .lyric = tester.hitTest(at: head) {
                Issue.record("notehead point resolved to a lyric")
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
