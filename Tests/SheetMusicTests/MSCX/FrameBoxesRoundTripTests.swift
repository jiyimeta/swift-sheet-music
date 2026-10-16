import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<VBox>`, `<TBox>` and `<HBox>` decode to typed values and write back byte-stable (import fidelity W7, Task 3).
@Suite("Frame boxes round trip")
struct FrameBoxesRoundTripTests {
    private func load(_ name: String) throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
    }

    /// Decodes the boxes of a `<Staff>` body written inline.
    private func decodeBlocks(_ body: String) throws -> [PositionedScoreBlock] {
        let staff = try XMLTreeParser.parse(Data("<Staff id=\"1\">\(body)</Staff>".utf8))
        return PositionedScoreBlock.decodeAll(inTopLevelStaff: staff)
    }

    private func vbox(_ positioned: PositionedScoreBlock) -> ScoreFrame? {
        if case let .verticalFrame(frame) = positioned.block { return frame }
        return nil
    }

    private func textFrame(_ positioned: PositionedScoreBlock) -> TextFrame? {
        if case let .textFrame(frame) = positioned.block { return frame }
        return nil
    }

    private func horizontalFrame(_ positioned: PositionedScoreBlock) -> HorizontalFrame? {
        if case let .horizontalFrame(frame) = positioned.block { return frame }
        return nil
    }

    // MARK: - frames-boxes.mscx

    @Test func boxesDecodeInOrderAtTheirMeasureIndexes() throws {
        let score = try load("frames-boxes")

        #expect(score.blocks.map(\.beforeMeasureIndex) == [0, 4, 8, 10, 12])
        #expect(vbox(score.blocks[0]) != nil)
        #expect(vbox(score.blocks[1]) != nil)
        #expect(textFrame(score.blocks[2]) != nil)
        #expect(horizontalFrame(score.blocks[3]) != nil)
        #expect(vbox(score.blocks[4]) != nil)
    }

    @Test func vboxBDecodesGapsAutoSizeAndPageBreak() throws {
        let score = try load("frames-boxes")
        let frame = try #require(vbox(score.blocks[1]))

        #expect(frame.heightSp == 6)
        #expect(frame.topGapSp == 4)
        #expect(frame.bottomGapSp == 5)
        #expect(frame.autoSize == false)
        #expect(frame.pageBreakAfter)
        #expect(frame.texts.first?.text == "Part II")
    }

    @Test func titleAndTrailingVBoxesKeepTheirOwnValues() throws {
        let score = try load("frames-boxes")
        let title = try #require(vbox(score.blocks[0]))
        let trailing = try #require(vbox(score.blocks[4]))

        #expect(title.heightSp == 10)
        #expect(title.autoSize == nil)
        #expect(title.topGapSp == nil)
        #expect(!title.pageBreakAfter)
        #expect(trailing.heightSp == 5)
        #expect(trailing.autoSize == false)
        #expect(trailing.texts.first?.text == "End")
    }

    @Test func textFrameDecodesMarginsAndText() throws {
        let score = try load("frames-boxes")
        let frame = try #require(textFrame(score.blocks[2]))

        #expect(frame.margins.top == 2)
        #expect(frame.margins.bottom == 2)
        #expect(frame.margins.left == 3)
        #expect(frame.margins.right == 0)
        #expect(frame.text?.text == "Interlude")
        #expect(frame.topGapSp == nil)
    }

    @Test func horizontalFrameDecodesItsWidth() throws {
        let score = try load("frames-boxes")
        let frame = try #require(horizontalFrame(score.blocks[3]))

        #expect(frame.widthSp == 6)
        #expect(frame.topGapSp == nil)
        #expect(frame.bottomGapSp == nil)
    }

    // MARK: - frames-pictures.mscx

    @Test func titleVBoxDecodesItsAutoScaledImage() throws {
        let score = try load("frames-pictures")
        let title = try #require(vbox(score.blocks[0]))
        let image = try #require(title.images.first)

        #expect(title.images.count == 1)
        #expect(image.path == "c30a2fc8801ac2ae196a1d9580695545.png")
        #expect(image.autoScale)
        #expect(image.size == nil)
        #expect(image.offsetSp == nil)
    }

    @Test func secondVBoxDecodesSizeOffsetAndDefaults() throws {
        let score = try load("frames-pictures")
        let second = try #require(vbox(score.blocks[1]))
        let image = try #require(second.images.first)

        #expect(score.blocks[1].beforeMeasureIndex == 2)
        #expect(second.autoSize == false)
        #expect(image.path == "099d26f8691e3a8bb734f122687d7220.jpg")
        #expect(image.size?.width == 12)
        #expect(image.size?.height == 6)
        #expect(image.offsetSp?.x == 1)
        #expect(image.offsetSp?.y == 0.5)
        #expect(!image.autoScale)
        #expect(image.lockAspectRatio)
        #expect(image.sizeIsSpatium)
    }

    // MARK: - Round trips

    @Test(arguments: ["frames-boxes", "frames-pictures"] as [String])
    func encodeThenDecodeKeepsEveryBlock(name: String) throws {
        let decoded = try load(name)
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(decoded))

        #expect(reparsed.blocks == decoded.blocks)
    }

    @Test func encodedBoxesKeepMuseScoresChildOrder() throws {
        let score = try load("frames-boxes")

        let vboxNode = score.blocks[1].block.encode()
        let tboxNode = score.blocks[2].block.encode()
        let hboxNode = score.blocks[3].block.encode()

        #expect(vboxNode.children.map(\.name) == [
            "height", "topGap", "bottomGap", "boxAutoSize", "Text", "LayoutBreak",
        ])
        #expect(tboxNode.children.map(\.name) == ["leftMargin", "topMargin", "bottomMargin", "Text"])
        #expect(hboxNode.children.map(\.name) == ["width"])
    }

    // MARK: - Inline cases

    @Test func hboxKeepsAnUnmodeledChild() throws {
        let blocks = try decodeBlocks("""
        <HBox><width>8</width><createSystemHeader>false</createSystemHeader></HBox>
        """)
        let block = try #require(blocks.first)
        let frame = try #require(horizontalFrame(block))

        let encoded = block.block.encode()

        #expect(frame.widthSp == 8)
        #expect(frame.preservedMarkup.map(\.name) == ["createSystemHeader"])
        #expect(encoded.first("createSystemHeader")?.text == "false")
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(encoded.first("width") != nil)
    }

    @Test func hboxGapsAreItsLeftAndRightGap() throws {
        let blocks = try decodeBlocks("<HBox><width>8</width><topGap>1</topGap><bottomGap>2</bottomGap></HBox>")
        let frame = try #require(blocks.first.flatMap(horizontalFrame))

        #expect(frame.topGapSp == 1)
        #expect(frame.bottomGapSp == 2)
    }

    @Test func imageUnderATBoxIsPreservedVerbatim() throws {
        let blocks = try decodeBlocks("""
        <TBox><Text><style>frame</style><text>x</text></Text><Image><path>p.png</path><z>7</z></Image></TBox>
        """)
        let block = try #require(blocks.first)
        let frame = try #require(textFrame(block))

        let image = block.block.encode().first("Image")

        #expect(frame.preservedMarkup.map(\.name) == ["Image"])
        #expect(image?.first("path")?.text == "p.png")
        #expect(image?.first("z")?.text == "7")
    }

    @Test func tboxWithoutATextHasNilText() throws {
        let blocks = try decodeBlocks("<TBox><topMargin>1</topMargin></TBox>")
        let frame = try #require(blocks.first.flatMap(textFrame))

        #expect(frame.text == nil)
        #expect(frame.margins.top == 1)
    }

    @Test func fretBoxStaysOpaque() throws {
        let blocks = try decodeBlocks("<FBox><fretFrameTextScale>1</fretFrameTextScale></FBox>")

        #expect(blocks.first?.block == .opaqueFrame(OpaqueFrame(
            kind: .fret,
            preservedMarkup: [PreservedXML(name: "fretFrameTextScale", text: "1")],
        )))
    }
}
