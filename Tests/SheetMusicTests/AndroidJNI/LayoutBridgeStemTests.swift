#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import Testing

    struct LayoutBridgeStemTests {
        private let _installApple = TestSupport.installApple

        @Test
        func midi01EmitsStrokeCommands() throws {
            let url = try #require(Bundle.module.url(
                forResource: "midi01",
                withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            let encoded = LayoutBridge.compute(
                score: score,
                pageWidthMM: 210,
                pageHeightMM: 297,
            )
            let pages = try DrawProgramCodec.decode(encoded)
            #expect(!pages.isEmpty)
            // midi01 has 4 quarter notes; each chord now emits a
            // moveTo/lineTo/stroke triple for its stem in addition to
            // the staff-line strokes. Pre-refactor count was 6
            // (5 staff lines + 1 barline); post-refactor expectation
            // is 10 (+ 4 stems).
            var strokeCount = 0
            for page in pages {
                for cmd in page.commands {
                    if case .stroke = cmd { strokeCount += 1 }
                }
            }
            #expect(strokeCount == 10)
        }
    }
#endif
