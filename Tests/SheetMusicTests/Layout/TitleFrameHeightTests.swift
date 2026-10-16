#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// The title frame is as tall as the texts it places: its declared `<height>` is a minimum, and a text broken over
/// lines reaches as far down as its last line.
@Suite("Title frame height")
struct TitleFrameHeightTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// The fixture's frame declares a 10 sp height: at the default 28 pt staff that is room enough for both subtitle
    /// lines, at a smaller staff it is not, and only the frame's own measure of its texts can keep the second line in.
    @Test(
        "the title frame grows to hold every line of a broken subtitle, not only its first",
        arguments: [20, 28] as [Double],
    )
    func holdsEveryLine(staffSize: Double) throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("rich-text"))
        let document = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(staffSize: CGFloat(staffSize)), availableWidth: 1200,
        )
        let frame = try #require(document.titleFrame)
        let last = try #require(frame.placedLines().last { $0.entryIndex == 1 })
        #expect(last.text == "arr. Second")
        let line = try #require(last.richLine)
        #expect(frame.height >= last.position.y + line.ascent + line.descent)
    }
}
