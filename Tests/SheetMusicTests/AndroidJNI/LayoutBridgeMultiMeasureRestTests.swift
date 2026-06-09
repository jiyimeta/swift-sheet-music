#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The Android draw-command bridge must engrave a collapsed
    /// multi-measure rest as the SMuFL `restHBar` glyph plus a centered
    /// run-length count, matching the Apple renderer — not the tiny
    /// placeholder rect the case was originally stubbed with.
    struct LayoutBridgeMultiMeasureRestTests {
        private let _installApple = TestSupport.installApple

        private static func restMeasure() -> Measure {
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        }

        private static func score(_ measures: [Measure]) -> Score {
            Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: measures)],
                )],
                systemMeasures: Array(
                    repeating: SystemMeasure(), count: measures.count,
                ),
            )
        }

        private static func collapsedCommands() -> [DrawCommand] {
            guard #available(macOS 15.0, iOS 16.0, *) else { return [] }
            let s = score([
                restMeasure(), restMeasure(),
                restMeasure(), restMeasure(),
            ])
            let opts = ScoreViewOptions(
                multiMeasureRest: .collapse(minimumMeasures: 2),
            )
            let doc = LayoutEngine.layout(
                score: s, options: opts, availableWidth: 1200,
            )
            return LayoutBridge.buildCommands(layout: doc)
        }

        @Test("collapsed run emits the restHBar glyph")
        func emitsHBarGlyph() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.collapsedCommands()
            let hasHBar = commands.contains { cmd in
                if case let .glyph(codepoint, _, _, _, _) = cmd {
                    return codepoint == SMuFLCodepoint.restHBar
                }
                return false
            }
            #expect(hasHBar)
        }

        @Test("collapsed run emits the measure count above the bar")
        func emitsCountText() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.collapsedCommands()
            let hasCount = commands.contains { cmd in
                if case let .text(text, _, _, _, _) = cmd {
                    return text == "4"
                }
                return false
            }
            #expect(hasCount)
        }

        @Test("collapsed run no longer emits a placeholder rect")
        func noPlaceholderRect() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let commands = Self.collapsedCommands()
            let hasRect = commands.contains { cmd in
                if case .fillRect = cmd { return true }
                return false
            }
            #expect(!hasRect)
        }
    }
#endif
