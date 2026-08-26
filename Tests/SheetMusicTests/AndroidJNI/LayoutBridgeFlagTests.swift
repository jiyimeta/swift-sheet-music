#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import Testing

    struct LayoutBridgeFlagTests {
        private let _installApple = TestSupport.installApple

        @Test
        func midi01EmitsNoFlagsButPureSurvivedTo10Stroke() throws {
            // midi01 has 4 quarter notes — no eighth/16th durations
            // → expect 0 flag glyphs.
            let url = try #require(TestResources.url(
                forResource: "midi01", withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            let encoded = LayoutBridge.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
            )
            let pages = try DrawProgramCodec.decode(encoded)
            let flagCount = countFlagGlyphs(in: pages)
            #expect(flagCount == 0)
        }

        private func countFlagGlyphs(in pages: [EncodablePage]) -> Int {
            let flagCodepoints: Set<UInt32> = [
                0xE240, 0xE241, 0xE242, 0xE243,
                0xE244, 0xE245, 0xE246, 0xE247,
            ]
            var count = 0
            for page in pages {
                for cmd in page.commands {
                    if case let .glyph(cp, _, _, _, _) = cmd,
                       flagCodepoints.contains(cp)
                    {
                        count += 1
                    }
                }
            }
            return count
        }
    }
#endif
