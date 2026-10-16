#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// See `TitleBlockAlignTests`: anchor to SheetMusicLayout's own `CGFloat` off Apple.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// The frame builder: a `<VBox>` or `<TBox>` after the title, as layout geometry. Text-dependent numbers are
/// relations; geometry that touches no text is asserted in exact sp multiples.
@Suite("Frame layout") struct FrameLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// `sp = 10`.
    private let metrics = StaffMetrics(staffSize: 40)
    private let mmToPt: CGFloat = 72.0 / 25.4

    /// A PNG that is only its signature and `IHDR` chunk: `ImageSniffer` never inflates.
    private func pngHeader(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        for value in [width, height] {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        bytes.append(contentsOf: [8, 6, 0, 0, 0, 0, 0, 0, 0])
        return Data(bytes)
    }

    private func textFrame(_ text: String?, margins: FrameMargins = FrameMargins()) -> ScoreBlock {
        let frameText = text.map { FrameText(style: .other, text: $0, otherStyleName: "frame") }
        return .textFrame(TextFrame(text: frameText, margins: margins))
    }

    private func layout(_ block: ScoreBlock, pictures: [String: Data] = [:]) -> LayoutFrame? {
        LayoutEngine.layoutFrame(
            block, style: .museScoreDefaults, metrics: metrics, docWidth: 200, pictures: pictures,
        )
    }

    private func closeEnough(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.01
    }

    @Test("a text frame is as tall as its text plus the top and bottom margins")
    func textFrameHeightIsTextPlusMargins() throws {
        let bare = try #require(layout(textFrame("Hello")))
        let margined = try #require(layout(textFrame("Hello", margins: FrameMargins(left: 3, top: 2, bottom: 2))))
        #expect(closeEnough(margined.height - bare.height, 4 * mmToPt))
        let text = try #require(margined.content.texts.first)
        #expect(closeEnough(text.position.x, 3 * mmToPt))
        #expect(closeEnough(text.position.y, 2 * mmToPt))
        #expect(text.anchor == .topLeading)
        #expect(margined.kind == .text)
    }

    @Test("a text frame without a text still takes the face's ascent")
    func emptyTextFrameTakesTheAscent() throws {
        let frame = try #require(layout(textFrame(nil)))
        #expect(frame.height > 0)
    }

    @Test("a vertical frame's texts come from the title builder")
    func verticalFrameKeepsTheTitleBuilder() throws {
        let source = ScoreFrame(
            heightSp: 6,
            texts: [FrameText(style: .title, text: "Song"), FrameText(style: .composer, text: "Me")],
            autoSize: false,
        )
        let frame = try #require(layout(.verticalFrame(source)))
        let expected = LayoutEngine.buildTitleFrame(
            source: source, style: .museScoreDefaults, metrics: metrics, docWidth: 200,
        )
        #expect(frame.content.texts == expected.texts)
        #expect(frame.kind == .vertical)
    }

    @Test("an autoScale picture is fitted into the box, keeping its native ratio")
    func imageFitsAutoScale() throws {
        let source = ScoreFrame(heightSp: 6, texts: [], images: [FrameImage(path: "a.png", autoScale: true)])
        let pictures = ["a.png": pngHeader(width: 40, height: 20)]
        let tall = LayoutEngine.layoutImages(of: source, pictures: pictures, docWidth: 200, fitHeight: 60, sp: 10)
        let first = try #require(tall.first)
        #expect(first.format == .png)
        #expect(closeEnough(first.rect.width, 120))
        #expect(closeEnough(first.rect.height, 60))
        let flat = LayoutEngine.layoutImages(of: source, pictures: pictures, docWidth: 200, fitHeight: 10, sp: 10)
        let second = try #require(flat.first)
        #expect(closeEnough(second.rect.width, 20))
        #expect(closeEnough(second.rect.height, 10))
    }

    @Test("a picture with a written size is that many spatium, placed at its offset")
    func fixedSizeImage() throws {
        let image = FrameImage(path: "a.png", size: CGSize(width: 12, height: 6), offsetSp: CGPoint(x: 1, y: 0.5))
        let source = ScoreFrame(heightSp: 6, texts: [], images: [image])
        let placed = LayoutEngine.layoutImages(
            of: source, pictures: ["a.png": pngHeader(width: 40, height: 20)], docWidth: 200, fitHeight: 60, sp: 10,
        )
        let first = try #require(placed.first)
        #expect(first.rect == CGRect(x: 10, y: 5, width: 120, height: 60))
    }

    @Test("an SVG, an unreadable payload and a missing path lay out no picture, and the frame still lays out")
    func undecodablePictureIsKeptNotLaidOut() throws {
        let images = [
            FrameImage(path: "s.svg"), FrameImage(path: "j.png"), FrameImage(path: "missing.png"),
        ]
        let source = ScoreFrame(heightSp: 6, texts: [], images: images)
        let pictures = [
            "s.svg": Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8),
            "j.png": Data([1, 2, 3, 4, 5, 6, 7]),
        ]
        let frame = try #require(layout(.verticalFrame(source), pictures: pictures))
        #expect(frame.images == [])
        #expect(frame.height > 0)
    }

    @Test("an autosized frame is widened to the lowest picture bottom")
    func heightGrowsToTheImage() throws {
        let image = FrameImage(path: "a.png", size: CGSize(width: 8, height: 14))
        let source = ScoreFrame(heightSp: 6, texts: [], images: [image])
        let frame = try #require(layout(.verticalFrame(source), pictures: ["a.png": pngHeader(width: 40, height: 20)]))
        #expect(frame.height == 14 * metrics.sp)
        #expect(frame.images.count == 1)
    }

    @Test("a fixed-height frame does not grow to its picture")
    func fixedHeightDoesNotGrow() throws {
        let image = FrameImage(path: "a.png", size: CGSize(width: 8, height: 14))
        let source = ScoreFrame(heightSp: 6, texts: [], autoSize: false, images: [image])
        let frame = try #require(layout(.verticalFrame(source), pictures: ["a.png": pngHeader(width: 40, height: 20)]))
        #expect(frame.height == 6 * metrics.sp)
        #expect(frame.images.count == 1)
    }

    @Test("an autosized frame is at least 10 sp tall however small its height is written")
    func autosizedFrameIsAtLeastTenSp() throws {
        let source = ScoreFrame(heightSp: 6, texts: [FrameText(style: .composer, text: "x")])
        let frame = try #require(layout(.verticalFrame(source)))
        #expect(frame.height >= 10 * metrics.sp)
    }

    @Test("a fixed frame keeps exactly the height it is written with")
    func fixedFrameKeepsItsHeight() throws {
        let source = ScoreFrame(heightSp: 6, texts: [FrameText(style: .composer, text: "x")], autoSize: false)
        let frame = try #require(layout(.verticalFrame(source)))
        #expect(frame.height == 6 * metrics.sp)
    }
}
