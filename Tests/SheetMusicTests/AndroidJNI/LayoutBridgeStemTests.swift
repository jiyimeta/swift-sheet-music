#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
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
            // element: 5 staff lines + 2 bar lines + 4 stems
            // + 2 ledger lines = 13. The two bar lines are the left
            // initial system line (closing the staff's left edge) and
            // the right end bar line — both are real engraving elements
            // that also render in the production CALayer / PDF path.
            // (An earlier expectation of 10 counted only the end bar
            // line; 11 predates the bridge drawing ledger lines.)
            // Only 2 of the 4 notes take a ledger line: the pitches are
            // C4, C#4, D4, D#4 (staff steps -6, -6, -5, -5). In treble
            // clef the bottom staff line is E4, so the two C naturals /
            // sharps sit one line below the staff and need a ledger,
            // while the two Ds sit in the SPACE just below the bottom
            // line and need none.
            var strokeCount = 0
            for page in pages {
                for cmd in page.commands {
                    if case .stroke = cmd { strokeCount += 1 }
                }
            }
            #expect(strokeCount == 13)
        }
    }
#endif
