#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing

    /// End-to-end test: a parenthesized note round-trips through LayoutBridge
    /// and produces `.glyph` DrawCommands with the SMuFL left/right paren
    /// codepoints (0xE0F5 / 0xE0F6). Also proves Task 7's LayoutChordNote
    /// parentheses carry reaches the Android emit path.
    struct LayoutBridgeNoteParenthesesTests {
        private let _installApple = TestSupport.installApple

        /// Returns `(codepoint, x)` for every `.glyph` DrawCommand in the
        /// rendered score so callers can check both presence and position.
        private func glyphCodepointXPairs(
            parentheses: NoteParentheses,
        ) throws -> [(cp: UInt32, x: Double)] {
            let note = Note(pitch: 60, tpc: 14, parentheses: parentheses)
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [note])),
            ])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure])],
                )],
            )
            let encoded = LayoutBridge.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
            )
            let pages = try DrawProgramCodec.decode(encoded)
            var pairs: [(cp: UInt32, x: Double)] = []
            for page in pages {
                for cmd in page.commands {
                    if case let .glyph(cp, x, _, _, _) = cmd { pairs.append((cp: cp, x: x)) }
                }
            }
            return pairs
        }

        @Test func bothParenthesesEmitLeftAndRightGlyphs() throws {
            let pairs = try glyphCodepointXPairs(parentheses: .both)
            let cps = pairs.map(\.cp)
            #expect(cps.contains(0xE0F5)) // noteheadParenthesisLeft
            #expect(cps.contains(0xE0F6)) // noteheadParenthesisRight
            // Position assertion: left paren must sit left of the notehead
            // (0xE0A4 = noteheadBlack) and the notehead left of the right paren.
            let leftParenX = try #require(pairs.first(where: { $0.cp == 0xE0F5 })?.x)
            let headX = try #require(pairs.first(where: { $0.cp == 0xE0A4 })?.x)
            let rightParenX = try #require(pairs.first(where: { $0.cp == 0xE0F6 })?.x)
            #expect(leftParenX < headX)
            #expect(headX < rightParenX)
        }

        @Test func noneEmitsNeitherParenthesis() throws {
            let pairs = try glyphCodepointXPairs(parentheses: .none)
            let cps = pairs.map(\.cp)
            #expect(!cps.contains(0xE0F5))
            #expect(!cps.contains(0xE0F6))
        }
    }
#endif
