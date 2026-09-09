#if os(macOS)
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicEditWire
    @testable import SheetMusicLayout
    import Testing

    /// Naming an engraved text as a selectable item: `ScoreTextID`, the `ScoreItemID.text` case that carries
    /// it, and the two directions between it and `ScoreHitTarget`.
    ///
    /// The property that matters is that a HIT becomes a SELECTION with nothing in between: whatever
    /// `hitTest(at:)` reports for a text must round-trip into a `ScoreItemID` and back to the identical
    /// target. If those two vocabularies could drift, a host would need a translation table and every entry
    /// in it would be a place to get the identity subtly wrong.
    @Suite("Text selection — identity")
    struct ScoreTextSelectionIdentityTests {
        private let _installApple = TestSupport.installApple

        /// Element index 1 of bar 0 — the first of the fixture's two C4 quarters, the same anchor
        /// `ScoreHitTesterTextRectTests` writes its text against.
        private static let anchor = VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        private static let allFour: [ScoreTextID] = [
            .lyric(anchor: anchor, verse: 1),
            .staffText(anchor: anchor, style: .systemText),
            .harmony(anchor: anchor),
            .rehearsalMark(measureIndex: 3),
        ]

        @Test("Every text identity round-trips through ScoreHitTarget and back")
        func targetRoundTrip() {
            for id in Self.allFour {
                let target = ScoreHitTarget(textID: id)
                #expect(target.textID == id, "\(id) did not survive the trip through \(target)")
                #expect(target.selectableItem == .text(id))
            }
        }

        @Test("A non-text target has no text identity, and still names its own item")
        func nonTextTargetsAreUnaffected() {
            let note = NoteID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            )
            #expect(ScoreHitTarget.note(note).textID == nil)
            #expect(ScoreHitTarget.note(note).selectableItem == .note(note))
            // `.stem` resolves to the first notehead it carries, exactly as `editingHitTest` does.
            #expect(ScoreHitTarget.stem(notes: [note]).selectableItem == .note(note))
            #expect(ScoreHitTarget.stem(notes: []).selectableItem == nil)
        }

        @Test("An anchored text answers ScoreItemID's positional accessors from its anchor")
        func anchoredTextPosition() {
            let item = ScoreItemID.text(.lyric(anchor: Self.anchor, verse: 2))
            #expect(item.staff == Self.anchor.staff)
            #expect(item.measureIndex == Self.anchor.measureIndex)
            #expect(item.voiceIndex == Self.anchor.voiceIndex)
            #expect(item.elementIndex == Self.anchor.elementIndex)
            #expect(item.textID == .lyric(anchor: Self.anchor, verse: 2))
        }

        @Test("A rehearsal mark answers by bar, and approximates the rest on the top staff")
        func rehearsalMarkPosition() {
            let item = ScoreItemID.text(.rehearsalMark(measureIndex: 7))
            // The bar is the mark's real identity and is exact.
            #expect(item.measureIndex == 7)
            // The other three are the documented approximation: a system element engraved once, on the
            // score's top staff. `voiceIndex` in particular decides which voice color the tint uses.
            #expect(item.staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
            #expect(item.voiceIndex == 0)
            #expect(item.elementIndex == 0)
        }

        @Test("Only a text item reports a textID")
        func textIDIsTheOneTest() {
            #expect(ScoreItemID.text(.harmony(anchor: Self.anchor)).textID != nil)
            #expect(ScoreItemID.clef(.staffDefault(EditingFixtures.staff0)).textID == nil)
        }

        @Test("An engraved lyric's hit target becomes the selection that names it")
        func hitBecomesSelection() throws {
            guard #available(macOS 15.0, *) else { return }
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)

            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)
            let target = ScoreHitTarget.lyric(anchor: Self.anchor, verse: 0)
            let rect = try #require(tester.textHitRect(for: target))
            let hit = try #require(tester.hitTest(at: CGPoint(x: rect.midX, y: rect.midY)))

            // The whole point: one call from the click to the item a `ScoreSelection` carries.
            #expect(hit.selectableItem == .text(.lyric(anchor: Self.anchor, verse: 0)))
        }

        @Test("A text selection expands to itself — one syllable, not the verse row")
        func selectionExpandsToOneElement() throws {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)
            let sibling = VoiceElementID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: Self.anchor.elementIndex + 1,
            )
            _ = try SetLyric(at: sibling, verse: 0, text: "ri").apply(to: &score)

            let item = ScoreItemID.text(.lyric(anchor: Self.anchor, verse: 0))
            let expanded = SelectionExpansion.selectedIDs(for: .single(item), in: score)
            #expect(expanded == [item])
            // The control: the row's other syllable exists and is a different item, so the singleton above
            // is a decision rather than the second syllable being absent.
            #expect(!expanded.contains(.text(.lyric(anchor: sibling, verse: 0))))
        }

        @Test("Every text identity survives the wire")
        func wireRoundTrip() throws {
            for id in Self.allFour {
                let item = ScoreItemID.text(id)
                let data = ScoreItemIDCodec.encode(item)
                #expect(try ScoreItemIDCodec.decode(data) == item, "\(id) did not survive the wire")
            }
        }

        @Test("Appending the text case did not renumber the four that were already on the wire")
        func wireCaseIndicesAreStable() {
            // Case indices are part of the format (`ScoreItemIDCodec`'s doc): the payload is
            // varint(caseIndex) + the case's own encoding, so the first payload byte is the index. Reading
            // it back through the enum rather than the bytes would pass no matter how they were numbered.
            let note = ScoreItemID.note(NoteID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            ))
            let clef = ScoreItemID.clef(.staffDefault(EditingFixtures.staff0))
            let text = ScoreItemID.text(.rehearsalMark(measureIndex: 0))
            #expect(Array(ScoreItemIDCodec.encode(note))[1] == 0)
            #expect(Array(ScoreItemIDCodec.encode(clef))[1] == 3)
            #expect(Array(ScoreItemIDCodec.encode(text))[1] == 4)
            let element = ScoreItemID.element(.keySignature(measureIndex: 0))
            #expect(Array(ScoreItemIDCodec.encode(element))[1] == 5)
            let rest = ScoreItemID.rest(RestID(
                staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
            ))
            let tuplet = ScoreItemID.tuplet(TupletID(
                staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, startElementIndex: 1,
            ))
            #expect(Array(ScoreItemIDCodec.encode(rest))[1] == 1)
            #expect(Array(ScoreItemIDCodec.encode(tuplet))[1] == 2)
        }
    }
#endif
