#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    /// End-to-end test: a parenthesized note round-trips through LayoutBridge
    /// and produces `.glyph` DrawCommands with the SMuFL left/right paren
    /// codepoints (0xE0F5 / 0xE0F6). Also proves Task 7's LayoutChordNote
    /// parentheses carry reaches the Android emit path.
    struct LayoutBridgeNoteParenthesesTests {
        private let _installApple = TestSupport.installApple

        private func glyphCodepoints(parentheses: NoteParentheses) throws -> [UInt32] {
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
            var cps: [UInt32] = []
            for page in pages {
                for cmd in page.commands {
                    if case let .glyph(cp, _, _, _, _) = cmd { cps.append(cp) }
                }
            }
            return cps
        }

        @Test func bothParenthesesEmitLeftAndRightGlyphs() throws {
            let cps = try glyphCodepoints(parentheses: .both)
            #expect(cps.contains(0xE0F5)) // noteheadParenthesisLeft
            #expect(cps.contains(0xE0F6)) // noteheadParenthesisRight
        }

        @Test func noneEmitsNeitherParenthesis() throws {
            let cps = try glyphCodepoints(parentheses: .none)
            #expect(!cps.contains(0xE0F5))
            #expect(!cps.contains(0xE0F6))
        }
    }
#endif
