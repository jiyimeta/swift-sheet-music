#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// Pins `LayoutBridge.buildCommands(layout:)` to emit a center-anchored
    /// SMuFL glyph for a `.breath` `LayoutElement`. The production wiring
    /// landed alongside the layout integration in Task 6; this guards against
    /// future regressions on the JNI surface (Android renderer entry point).
    @Suite("Breath JNI bridge")
    struct BreathJNITests {
        private let _installApple = TestSupport.installApple

        /// Build a single-measure score `[chord(C4), breath(kind), chord(D4)]`.
        /// Same canonical shape used by `BreathLayoutTests`; reproduced here
        /// because that helper is `private static` to its suite.
        private static func breathBetweenChordsScore(kind: Breath.Kind) -> Score {
            let cChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            )
            let dChord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
            )
            let breath = Breath(kind: kind, visible: true)
            let voice = Voice(elements: [
                .chord(cChord),
                .breath(breath),
                .chord(dChord),
            ])
            let measure = Measure(voices: [voice])
            let staff = Staff(measures: [measure])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                )],
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func layout(_ score: Score) -> LayoutDocument {
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(score: score, options: opts)
            return LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW,
            )
        }

        /// Count `DrawCommand.glyph` entries in `commands` whose codepoint
        /// matches `expected`.
        private static func glyphCount(
            _ commands: [DrawCommand],
            codepoint expected: UInt32,
        ) -> Int {
            var hits = 0
            for command in commands {
                if case let .glyph(codepoint, _, _, _, _) = command,
                   codepoint == expected
                {
                    hits += 1
                }
            }
            return hits
        }

        @Test("Caesura emits a glyph DrawCommand at U+E4D1")
        func caesuraEmitsGlyphCommand() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.breathBetweenChordsScore(kind: .caesura(.normal))
            let document = Self.layout(score)
            let commands = LayoutBridge.buildCommands(layout: document)
            #expect(Self.glyphCount(commands, codepoint: 0xE4D1) == 1)
        }

        @Test("Breath mark (.comma) emits a glyph DrawCommand at U+E4CE")
        func breathMarkCommaEmitsGlyphCommand() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Self.breathBetweenChordsScore(kind: .breathMark(.comma))
            let document = Self.layout(score)
            let commands = LayoutBridge.buildCommands(layout: document)
            #expect(Self.glyphCount(commands, codepoint: 0xE4CE) == 1)
        }
    }
#endif
