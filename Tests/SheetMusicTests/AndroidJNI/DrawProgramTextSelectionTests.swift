#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A selected engraved text (lyric, staff or system text, chord symbol, rehearsal mark) takes the selection tint
    /// in the draw program, the way Apple's renderer tints every layer registered under `LayoutElement.textItemID`.
    /// Split from `DrawProgramSelectionTests`, whose struct body is at SwiftLint's length cap.
    struct DrawProgramTextSelectionTests {
        private let _installApple = TestSupport.installApple

        private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let tintArgb: UInt32 = 0xFFAB_CDEF

        /// The chord every text is engraved on (voice element 1, after the time signature).
        private static let textAnchor = VoiceElementID(
            staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
        )

        private static var lyricID: ScoreItemID {
            .text(.lyric(anchor: textAnchor, verse: 0))
        }

        // MARK: - Helpers

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
        }

        private static func setColorIndices(_ commands: [DrawCommand], argb: UInt32) -> [Int] {
            commands.indices.filter {
                if case let .setColor(a) = commands[$0] { return a == argb }
                return false
            }
        }

        /// The single tint bracket in `commands` — the commands it holds, its close and the program with both
        /// removed — or `nil` when there is not exactly one.
        private static func bracketed(
            _ commands: [DrawCommand],
        ) -> (inner: ArraySlice<DrawCommand>, close: DrawCommand, stripped: [DrawCommand])? {
            let opens = setColorIndices(commands, argb: tintArgb)
            guard opens.count == 1, let open = opens.first,
                  let close = commands[(open + 1)...].firstIndex(where: {
                      if case .setColor = $0 { return true }
                      return false
                  })
            else { return nil }
            var stripped = commands
            stripped.remove(at: close)
            stripped.remove(at: open)
            return (commands[(open + 1) ..< close], commands[close], stripped)
        }

        private static func plainScore() -> Score {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        private static func textScore(_ edit: (inout Score) throws -> Void) rethrows -> Score {
            var score = plainScore()
            try edit(&score)
            return score
        }

        private static func lyricScore(color: ScoreColor? = nil) throws -> Score {
            try textScore { score in
                _ = try SetLyric(at: textAnchor, verse: 0, text: "glo").apply(to: &score)
                guard let color, case var .chord(chord)? = score[textAnchor] else { return }
                chord.lyrics[0].elementProperties.color = color
                score[textAnchor] = .chord(chord)
            }
        }

        private static func drawnText(_ commands: ArraySlice<DrawCommand>) -> String {
            commands.compactMap {
                if case let .text(text, _, _, _, _) = $0 { return text }
                return nil
            }.joined()
        }

        private static func hasGlyph(_ commands: ArraySlice<DrawCommand>) -> Bool {
            commands.contains {
                if case .glyph = $0 { return true }
                return false
            }
        }

        private static func hasStroke(_ commands: ArraySlice<DrawCommand>) -> Bool {
            commands.contains {
                if case .stroke = $0 { return true }
                return false
            }
        }

        // MARK: - Tests

        /// A selected lyric draws in the selection color through `textItemID`, the identity a tap on it selects, and
        /// the tint repaints without moving or adding ink.
        @Test("a selected lyric is tinted and nothing else is")
        func aSelectedLyricIsTinted() throws {
            let doc = try Self.layout(Self.lyricScore())
            let untinted = LayoutBridge.buildCommands(layout: doc)
            let tinted = LayoutBridge.buildCommands(layout: doc, tint: (argb: Self.tintArgb, ids: [Self.lyricID]))
            let bracket = try #require(Self.bracketed(tinted))
            #expect(Self.drawnText(bracket.inner).contains("glo"))
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
            #expect(bracket.stripped == untinted)
        }

        @Test("a selected staff text is tinted")
        func aSelectedStaffTextIsTinted() throws {
            let score = try Self.textScore { score in
                _ = try SetStaffText(anchor: Self.textAnchor, text: "solo", isSystemText: false).apply(to: &score)
            }
            let doc = Self.layout(score)
            let id = ScoreItemID.text(.staffText(anchor: Self.textAnchor, style: .staffText))
            let tinted = LayoutBridge.buildCommands(layout: doc, tint: (argb: Self.tintArgb, ids: [id]))
            let bracket = try #require(Self.bracketed(tinted))
            #expect(Self.drawnText(bracket.inner).contains("solo"))
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
            #expect(bracket.stripped == LayoutBridge.buildCommands(layout: doc))
        }

        /// A flat root typesets as an Edwin text run plus a Bravura accidental glyph run; both belong to the one
        /// symbol and sit inside the one bracket.
        @Test("a selected chord symbol is tinted, accidental runs included")
        func aSelectedChordSymbolIsTintedIncludingItsAccidentalRuns() throws {
            let score = try Self.textScore { score in
                _ = try SetChordSymbol(at: Self.textAnchor, name: "Bbm7").apply(to: &score)
            }
            // The symbol is spliced in immediately before the chord it names, shifting that chord's index by one.
            let named = VoiceElementID(
                staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: Self.textAnchor.elementIndex + 1,
            )
            let doc = Self.layout(score)
            let id = ScoreItemID.text(.harmony(anchor: named))
            let tinted = LayoutBridge.buildCommands(layout: doc, tint: (argb: Self.tintArgb, ids: [id]))
            let bracket = try #require(Self.bracketed(tinted))
            #expect(!Self.drawnText(bracket.inner).isEmpty)
            #expect(Self.hasGlyph(bracket.inner), "the accidental run is outside the tint")
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
            #expect(bracket.stripped == LayoutBridge.buildCommands(layout: doc))
        }

        @Test("a selected rehearsal mark tints its text and its frame")
        func aSelectedRehearsalMarkTintsTextAndFrame() throws {
            let score = try Self.textScore { score in
                _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
            }
            let doc = Self.layout(score)
            let id = ScoreItemID.text(.rehearsalMark(measureIndex: 0))
            let tinted = LayoutBridge.buildCommands(layout: doc, tint: (argb: Self.tintArgb, ids: [id]))
            let bracket = try #require(Self.bracketed(tinted))
            #expect(Self.drawnText(bracket.inner).contains("A"))
            #expect(Self.hasStroke(bracket.inner), "the frame is outside the tint")
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
            #expect(bracket.stripped == LayoutBridge.buildCommands(layout: doc))
        }

        /// The tint wins over the author color for the text's own commands, and the color after it is the ambient
        /// one — the author's green does not reappear, and does not leak past the text.
        @Test("an author-colored text returns to the ambient color after its tint")
        func anAuthorColoredTextReturnsToAmbientAfterItsTint() throws {
            let green = ScoreColor(red: 0, green: 128, blue: 0)
            let authorArgb = try #require(LayoutBridge.argb(from: green))
            let doc = try Self.layout(Self.lyricScore(color: green))

            // The control: unselected, the author color really is on the wire.
            let untinted = LayoutBridge.buildCommands(layout: doc)
            #expect(!Self.setColorIndices(untinted, argb: authorArgb).isEmpty)

            let tinted = LayoutBridge.buildCommands(layout: doc, tint: (argb: Self.tintArgb, ids: [Self.lyricID]))
            #expect(Self.setColorIndices(tinted, argb: authorArgb).isEmpty)
            let bracket = try #require(Self.bracketed(tinted))
            #expect(Self.drawnText(bracket.inner).contains("glo"))
            #expect(bracket.close == .setColor(argb: LayoutBridge.blackARGB))
        }

        @Test("an unselected text keeps its author color")
        func anUnselectedTextKeepsItsAuthorColor() throws {
            let green = ScoreColor(red: 0, green: 128, blue: 0)
            let authorArgb = try #require(LayoutBridge.argb(from: green))
            let doc = try Self.layout(Self.lyricScore(color: green))
            let untinted = LayoutBridge.buildCommands(layout: doc)
            // Another text selected: this lyric's program is untouched.
            let otherID = ScoreItemID.text(.lyric(anchor: Self.textAnchor, verse: 1))
            let tinted = LayoutBridge.buildCommands(layout: doc, tint: (argb: Self.tintArgb, ids: [otherID]))
            #expect(tinted == untinted)
            #expect(!Self.setColorIndices(tinted, argb: authorArgb).isEmpty)
            #expect(Self.setColorIndices(tinted, argb: Self.tintArgb).isEmpty)
        }
    }
#endif
