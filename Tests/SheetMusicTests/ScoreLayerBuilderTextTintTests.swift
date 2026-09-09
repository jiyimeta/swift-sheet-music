#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// Tinting an engraved text as a selected object, through the same `attach` / `applySelection` path a
    /// notehead, rest, clef and tuplet already use.
    ///
    /// Two things have to be true for that path to reach text at all: the text's layers must be registered
    /// under the `ScoreItemID` a selection would carry, and re-tinting them must be undoable. Both are
    /// asserted against the built layers rather than against the code that builds them.
    @Suite("ScoreLayerBuilder — text tint")
    struct ScoreLayerBuilderTextTintTests {
        private let _installApple = TestSupport.installApple

        private static let anchor = VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        /// The CGColor voice 0 actually resolves to, read back from the render state rather than rebuilt
        /// here — `Color.red` converts through `NSColor`, and a same-components CGColor in a different
        /// color space does not compare equal.
        @available(macOS 15.0, *)
        private func selectedColor(_ state: SelectionRenderState) throws -> CGColor {
            try #require(state.voiceColors[0])
        }

        @available(macOS 15.0, *)
        private func layout(_ score: Score) throws -> (system: LayoutSystem, metrics: StaffMetrics) {
            _ = BravuraFont.register
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 600,
            )
            return try (#require(doc.systems.first), doc.metrics)
        }

        @available(macOS 15.0, *)
        private func build(_ score: Score) throws -> ScoreLayerBuilder.SystemLayers {
            let (system, metrics) = try layout(score)
            return ScoreLayerBuilder.buildSystemWithItems(system, metrics: metrics)
        }

        @available(macOS 15.0, *)
        private func renderState(_ selection: ScoreSelection, in score: Score) -> SelectionRenderState {
            SelectionRenderState.make(
                selection: selection, voiceColors: [0: Color.red], score: score,
            )
        }

        /// Every attached layer must carry ink `applySelection` can actually overwrite — a layer with
        /// neither fill nor stroke would be registered and then silently never change color.
        private func expectTintable(
            _ layers: [CAShapeLayer], _ label: String,
        ) {
            #expect(!layers.isEmpty, "\(label) registered no layers")
            #expect(
                layers.allSatisfy { $0.fillColor != nil || $0.strokeColor != nil },
                "\(label) registered a layer with neither fill nor stroke",
            )
        }

        @available(macOS 15.0, *)
        @Test("A lyric syllable is registered under the item a selection names")
        func lyricIsRegistered() throws {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)
            let built = try build(score)
            let item = ScoreItemID.text(.lyric(anchor: Self.anchor, verse: 0))
            try expectTintable(#require(built.items[item]), "the lyric")
        }

        @available(macOS 15.0, *)
        @Test("A staff text, a chord symbol and a rehearsal mark are registered too")
        func theOtherThreeAreRegistered() throws {
            var staffTextScore = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetStaffText(
                anchor: Self.anchor, text: "solo", isSystemText: false,
            ).apply(to: &staffTextScore)
            try expectTintable(
                #require(try build(staffTextScore).items[
                    .text(.staffText(anchor: Self.anchor, style: .staffText)),
                ]),
                "the staff text",
            )

            var harmonyScore = EditingFixtures.twoConsecutiveC4Chords()
            // A flat root, so the symbol typesets as more than one run: an Edwin text run and a Bravura
            // accidental glyph run. Both belong to the same symbol and must tint together.
            _ = try SetChordSymbol(at: Self.anchor, name: "Bbm7").apply(to: &harmonyScore)
            // The symbol is spliced in immediately BEFORE the chord it names, so the named chord's element
            // index has shifted by one — the same offset `ScoreHitTesterTextRectTests` documents.
            let named = VoiceElementID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: Self.anchor.elementIndex + 1,
            )
            let (harmonySystem, harmonyMetrics) = try layout(harmonyScore)
            let harmonyBuilt = ScoreLayerBuilder.buildSystemWithItems(
                harmonySystem, metrics: harmonyMetrics,
            )
            let harmonyLayers = try #require(harmonyBuilt.items[.text(.harmony(anchor: named))])
            expectTintable(harmonyLayers, "the chord symbol")
            // Every run the layout typeset is registered — counted from the element itself rather than
            // guessed, so this cannot pass by drawing fewer runs than the symbol has.
            let runCount = harmonySystem.measures.flatMap(\.elements).compactMap { element -> Int? in
                guard case let .harmony(lh) = element else { return nil }
                return lh.runs.count
            }.first ?? 0
            #expect(runCount > 1, "the fixture symbol typeset as a single run; nothing to check")
            #expect(
                harmonyLayers.count == runCount,
                "\(harmonyLayers.count) of \(runCount) runs registered for the chord symbol",
            )

            var markScore = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &markScore)
            try expectTintable(
                #require(try build(markScore).items[.text(.rehearsalMark(measureIndex: 0))]),
                "the rehearsal mark",
            )
        }

        @available(macOS 15.0, *)
        @Test("Selecting a lyric tints it, and deselecting restores the ink it was built with")
        func tintAndRestore() throws {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)
            let built = try build(score)
            let item = ScoreItemID.text(.lyric(anchor: Self.anchor, verse: 0))
            let layers = try #require(built.items[item])
            let before = layers.map(\.fillColor)

            let selected = renderState(.single(item), in: score)
            let tint = try selectedColor(selected)
            ScoreLayerBuilder.applySelection(
                items: built.items, previousSelection: .empty, newSelection: selected,
            )
            #expect(
                layers.allSatisfy { $0.fillColor == tint },
                "the syllable did not take the selection color",
            )

            ScoreLayerBuilder.applySelection(
                items: built.items,
                previousSelection: selected,
                newSelection: renderState(.none, in: score),
            )
            #expect(layers.map(\.fillColor) == before, "deselecting did not restore the original ink")
        }

        @available(macOS 15.0, *)
        @Test("Deselecting an author-colored lyric restores the author's color, not black")
        func authorColorSurvivesASelection() throws {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.anchor, verse: 0, text: "glo").apply(to: &score)
            let authorColor = ScoreColor(red: 0, green: 128, blue: 0)
            var element = try #require(score[Self.anchor])
            guard case var .chord(chord) = element else {
                Issue.record("fixture element \(Self.anchor) is not a chord")
                return
            }
            chord.lyrics[0].elementProperties.color = authorColor
            element = .chord(chord)
            score[Self.anchor] = element

            let built = try build(score)
            let item = ScoreItemID.text(.lyric(anchor: Self.anchor, verse: 0))
            let layers = try #require(built.items[item])
            let green = ScoreLayerBuilder.scoreColorToCGColor(authorColor)
            // The control: the layer really was built green, so the restore below is restoring something
            // other than the default ink.
            #expect(
                layers.allSatisfy { $0.fillColor == green },
                "the fixture's author color never reached the layer",
            )

            let selected = renderState(.single(item), in: score)
            let tint = try selectedColor(selected)
            ScoreLayerBuilder.applySelection(
                items: built.items, previousSelection: .empty, newSelection: selected,
            )
            #expect(layers.allSatisfy { $0.fillColor == tint })

            ScoreLayerBuilder.applySelection(
                items: built.items,
                previousSelection: selected,
                newSelection: renderState(.none, in: score),
            )
            #expect(
                layers.allSatisfy { $0.fillColor == green },
                "deselecting reset the author's green to the default ink",
            )
        }

        @available(macOS 15.0, *)
        @Test("The hyphen between two syllables keeps its own ink while one of them is selected")
        func theHyphenIsNotPartOfTheSelection() throws {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(
                at: Self.anchor, verse: 0, text: "glo", syllabic: .begin,
            ).apply(to: &score)
            let sibling = VoiceElementID(
                staff: EditingFixtures.staff0,
                measureIndex: 0, voiceIndex: 0, elementIndex: Self.anchor.elementIndex + 1,
            )
            _ = try SetLyric(
                at: sibling, verse: 0, text: "ri", syllabic: .end,
            ).apply(to: &score)

            _ = BravuraFont.register
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 600,
            )
            let system = try #require(doc.systems.first)
            // The control: this fixture really does engrave a hyphen, so "no hyphen is registered" below
            // is a decision and not an empty score.
            let hyphens = system.measures.flatMap(\.elements).filter {
                if case .lyricHyphen = $0 { return true }
                return false
            }
            #expect(!hyphens.isEmpty, "the fixture engraved no hyphen to check")

            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: doc.metrics)
            // MuseScore draws the dashes from `LyricsLineSegment`, a separate item with its own
            // `curColor`, so selecting a syllable leaves them alone. Nothing here registers them under
            // either syllable's identity — the sum of the two syllables' layers is all the text layers
            // the builder attached in this bar.
            let glo = try #require(built.items[.text(.lyric(anchor: Self.anchor, verse: 0))])
            let ri = try #require(built.items[.text(.lyric(anchor: sibling, verse: 0))])
            let textItems = built.items.filter { $0.key.textID != nil }
            #expect(textItems.count == 2, "expected exactly the two syllables; got \(textItems.keys)")
            #expect(glo.count + ri.count == textItems.values.reduce(0) { $0 + $1.count })
        }
    }
#endif
