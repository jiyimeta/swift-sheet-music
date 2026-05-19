import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite("LayoutEngine — Android-compatible smoke")
struct LayoutEngineAndroidSmokeTests {
    #if !os(Android)
        private let _installApple = TestSupport.installApple
    #endif

    @available(macOS 15.0, *)
    @Test func midi01ScoreProducesNonEmptyLayoutDocument() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
        )
        let data = try Data(contentsOf: url)
        let score = try MSCXParser.parse(data)
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600,
        )
        #expect(!document.systems.isEmpty)
    }
}
