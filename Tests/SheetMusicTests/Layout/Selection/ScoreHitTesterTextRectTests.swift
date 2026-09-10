#if os(macOS)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    #if !canImport(CoreGraphics)
        /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
        /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
        ///
        /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
        /// with the same pattern in every other file in this target that needs it.
        private typealias CGFloat = SheetMusicLayout.CGFloat
        private typealias CGPoint = SheetMusicLayout.CGPoint
    #endif

    /// `ScoreHitTester.textHitRect(for:)` — the identity-keyed box behind the four text targets.
    ///
    /// The round trip is the property worth pinning: a target produced by `hitTest(at:)` must hand back a box
    /// whose own centre hit-tests to that same target. That is what a host draws a highlight from, and it is
    /// checkable without asserting any coordinate the engraving is free to move.
    @Suite("ScoreHitTester — text hit rect")
    struct ScoreHitTesterTextRectTests {
        private let _installApple = TestSupport.installApple

        /// Element index 1 of bar 0 — the first of the fixture's two C4 quarters.
        private static let anchor = VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        @available(macOS 15.0, *)
        private func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(
                score: ScoreEditor(score: score).score, options: ScoreViewOptions(), availableWidth: 600,
            )
        }

        @Test("Staff text adds click padding only outside its ink highlight")
        func installedTextPadding() throws {
            guard #available(macOS 15.0, *) else { return }
            let element = LayoutElement.staffText(
                text: "Fine", origin: ElementHitFixtures.origin, color: nil,
                style: .staffText, anchor: ElementHitFixtures.anchor,
            )
            let raw = try #require(TextInkGeometry.rects(for: element, metrics: ElementHitFixtures.metrics)?.first)
            let box = raw.offsetBy(dx: 50, dy: 50)
            let padded = box.insetBy(dx: -2.5, dy: -2.5)
            let target = ScoreHitTarget.staffText(anchor: ElementHitFixtures.anchor, style: .staffText)
            let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
            #expect(tester.textHitRect(for: target) == box)
            let hit = CGPoint(x: box.minX - 2.4, y: box.midY)
            #expect(padded.contains(hit))
            #expect(!box.contains(hit))
            #expect(tester.hitTest(at: hit) == target)
            let miss = CGPoint(x: box.minX - 2.6, y: box.midY)
            #expect(!padded.contains(miss))
            // Moving the text left by one point makes the same query fall within its padded rectangle.
            let shifted = LayoutElement.staffText(
                text: "Fine", origin: CGPoint(x: ElementHitFixtures.origin.x - 1, y: ElementHitFixtures.origin.y),
                color: nil, style: .staffText, anchor: ElementHitFixtures.anchor,
            )
            let control = ScoreHitTester(document: ElementHitFixtures.document([shifted]))
            #expect(padded.offsetBy(dx: -1, dy: 0).contains(miss))
            #expect(control.hitTest(at: miss) == target)
            #expect(tester.hitTest(at: miss) == nil)
        }

        @Test("A lyric's rect encloses the engraved origin and hit-tests back to the same lyric")
        func lyricRectRoundTrips() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let tester = ScoreHitTester(document: doc)
            let target = ScoreHitTarget.lyric(anchor: Self.anchor, verse: 0)
            let rect = try #require(tester.textHitRect(for: target))

            // The origin the DOCUMENT reports, never the box under test — the same discipline
            // `ScoreHitTesterTextTests` documents.
            let origin = try #require(doc.lyricEntryOrigin(
                at: LyricInputPlanner.Cursor(location: Self.anchor, verse: 0),
            ))
            #expect(rect.contains(origin))
            #expect(rect.width > 0 && rect.height > 0)
            #expect(tester.hitTest(at: CGPoint(x: rect.midX, y: rect.midY)) == target)
        }

        @Test("The rect is the ink box, not the padded click box")
        func rectExcludesTheClickTolerance() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let tester = ScoreHitTester(document: doc)
            let target = ScoreHitTarget.lyric(anchor: Self.anchor, verse: 0)
            let rect = try #require(tester.textHitRect(for: target))
            let tolerance = doc.metrics.sp * ScoreHitTester.textHitTolerance

            // A point just outside the returned box, but inside the padding, still resolves to the lyric —
            // which is only possible if the box handed back is the narrower of the two.
            let justOutside = CGPoint(x: rect.minX - tolerance / 2, y: rect.midY)
            #expect(!rect.contains(justOutside))
            #expect(tester.hitTest(at: justOutside) == target)
        }

        /// Every target's box round-trips through `hitTest`, exactly as the lyric one does.
        ///
        /// Each kind gets its own score rather than one score carrying all three, because a chord symbol is
        /// spliced in as its own voice element and shifts the indices the other anchors were written
        /// against — a coupling that would make a failure here ambiguous.
        private func expectRoundTrip(
            _ target: ScoreHitTarget, in score: Score,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let tester = ScoreHitTester(document: layout(score))
            let rect = try #require(tester.textHitRect(for: target), "no rect for \(target)")
            #expect(rect.width > 0 && rect.height > 0, "degenerate rect for \(target)")
            #expect(
                tester.hitTest(at: CGPoint(x: rect.midX, y: rect.midY)) == target,
                "the centre of \(target)'s own box does not hit-test back to it",
            )
        }

        @Test("A staff text's rect round-trips")
        func staffTextRectRoundTrips() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
            _ = try SetStaffText(
                anchor: Self.anchor, text: "solo", isSystemText: false,
            ).apply(to: &score)
            try expectRoundTrip(
                .staffText(anchor: Self.anchor, style: .staffText), in: score,
            )
        }

        @Test("A rehearsal mark's rect round-trips")
        func rehearsalMarkRectRoundTrips() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
            _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
            try expectRoundTrip(.rehearsalMark(measureIndex: 0), in: score)
        }

        @Test("A chord symbol's rect round-trips")
        func harmonyRectRoundTrips() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
            _ = try SetChordSymbol(at: Self.anchor, name: "Am7").apply(to: &score)
            // The symbol is spliced in immediately BEFORE the chord it names, so the named chord's element
            // index has shifted by one — and that shifted index is what `LayoutHarmony` carries.
            let named = VoiceElementID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: Self.anchor.elementIndex + 1,
            )
            try expectRoundTrip(.harmony(anchor: named), in: score)
        }

        @Test("A target no element carries answers nil rather than a neighbouring box")
        func absentTargetsAnswerNil() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = layout(score)
            let tester = ScoreHitTester(document: doc)
            // The control: verse 0 IS there, so a nil for verse 1 cannot be the walk failing wholesale.
            #expect(tester.textHitRect(
                for: .lyric(anchor: Self.anchor, verse: 0),
            ) != nil)
            #expect(tester.textHitRect(
                for: .lyric(anchor: Self.anchor, verse: 1),
            ) == nil)
            #expect(tester.textHitRect(for: .rehearsalMark(measureIndex: 0)) == nil)
            // A non-text target is not addressable here either, even though the note exists.
            #expect(tester.textHitRect(for: .note(NoteID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            ))) == nil)
        }
    }
#endif
