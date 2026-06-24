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
            // midi01 is a single 4/4 measure of 4 quarter notes. The
            // layout emits one moveTo/lineTo/stroke triple per stroked
            // element: 5 staff lines + 2 bar lines + 4 stems = 11. The
            // two bar lines are the left initial system line (closing the
            // staff's left edge) and the right end bar line — both are
            // real engraving elements that also render in the production
            // CALayer / PDF path. (An earlier expectation of 10 counted
            // only the end bar line.)
            var strokeCount = 0
            for page in pages {
                for cmd in page.commands {
                    if case .stroke = cmd { strokeCount += 1 }
                }
            }
            #expect(strokeCount == 11)
        }
    }
#endif
