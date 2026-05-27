#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import Testing
    import Wirelet

    struct LayoutBridgeTests {
        /// Ensures AppleFontMetricsProvider is installed so LayoutEngine's
        /// DEBUG assert does not fire on CoreText-capable hosts.
        private let _installApple = TestSupport.installApple

        @Test
        func emptyScoreProducesAtLeastOnePage() throws {
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
        }

        @Test
        func headerMagicAndVersionAreCorrect() throws {
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
            // Decode via DrawProgramWire to validate magic and version fields
            // without relying on positional byte offsets (TLV encoding places
            // fields as tag-prefixed varints, not at fixed offsets).
            let wire = try DrawProgramWire(decoding: encoded)
            #expect(wire.magic == DrawProgram.magic)
            #expect(wire.version == DrawProgram.version)
        }
    }
#endif
