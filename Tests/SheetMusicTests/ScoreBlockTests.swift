import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private enum BlockKind: Equatable {
    case vertical
    case horizontal
    case text
    case fret
}

private struct BlockPosition: Equatable {
    let beforeMeasureIndex: Int
    let kind: BlockKind
}

private func blockPositions(_ blocks: [PositionedScoreBlock]) -> [BlockPosition] {
    blocks.map { positioned in
        let kind: BlockKind = switch positioned.block {
        case .verticalFrame: .vertical
        case .textFrame: .text
        case .horizontalFrame: .horizontal
        case let .opaqueFrame(frame): switch frame.kind {
            case .horizontal: .horizontal
            case .text: .text
            case .fret: .fret
            }
        }
        return BlockPosition(
            beforeMeasureIndex: positioned.beforeMeasureIndex,
            kind: kind,
        )
    }
}

@Suite("Score blocks")
struct ScoreBlockTests {
    @Test func emptyScoreHasNoBlocksOrTitleFrame() {
        let score = Score(division: 480)
        #expect(score.titleFrame == nil)
        #expect(score.blocks.isEmpty)
    }

    @Test func titleFrameRoundTripsThroughComputedProperty() {
        var score = Score(division: 480)
        let frame = ScoreFrame(heightSp: 10, texts: [])

        score.titleFrame = frame

        #expect(score.titleFrame == frame)
        #expect(score.blocks == [
            PositionedScoreBlock(
                beforeMeasureIndex: 0,
                block: .verticalFrame(frame),
            ),
        ])

        score.titleFrame = nil
        #expect(score.titleFrame == nil)
        #expect(score.blocks.isEmpty)
    }

    @Test func initializerPlacesTitleFrameFirst() {
        let title = ScoreFrame(heightSp: 10, texts: [])
        let existing = PositionedScoreBlock(
            beforeMeasureIndex: 0,
            block: .opaqueFrame(OpaqueFrame(kind: .horizontal)),
        )

        let score = Score(
            division: 480,
            titleFrame: title,
            blocks: [existing],
        )

        #expect(score.blocks == [
            PositionedScoreBlock(
                beforeMeasureIndex: 0,
                block: .verticalFrame(title),
            ),
            existing,
        ])
    }

    @Test func fixtureDecodesEveryBlockAtItsDocumentPosition() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("score-blocks"))

        #expect(score.parts[0].staves[0].measures.count == 5)
        #expect(blockPositions(score.blocks) == [
            BlockPosition(beforeMeasureIndex: 0, kind: .vertical),
            BlockPosition(beforeMeasureIndex: 2, kind: .horizontal),
            BlockPosition(beforeMeasureIndex: 3, kind: .text),
            BlockPosition(beforeMeasureIndex: 4, kind: .fret),
        ])
        #expect(score.blocks.last?.beforeMeasureIndex == 4)
    }

    @Test func codaFixtureDecodesMidScoreHorizontalFrames() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("testCodaHBox_ref"))
        let horizontalIndices = score.blocks.compactMap { positioned -> Int? in
            guard case let .opaqueFrame(frame) = positioned.block,
                  frame.kind == .horizontal
            else { return nil }
            return positioned.beforeMeasureIndex
        }

        #expect(horizontalIndices == [5, 8])
    }

    @Test func multiMeasureRestContainerDoesNotAdvanceBlockIndex() throws {
        let data = Data("""
        <Staff id="1">
          <Measure/>
          <Measure><multiMeasureRest>4</multiMeasureRest></Measure>
          <HBox><width>8</width></HBox>
          <Measure/>
        </Staff>
        """.utf8)
        let staff = try XMLTreeParser.parse(data)

        let blocks = PositionedScoreBlock.decodeAll(inTopLevelStaff: staff)

        #expect(blocks.count == 1)
        #expect(blocks.first?.beforeMeasureIndex == 1)
    }

    @Test func encoderInterleavesBlocksInFirstTopLevelStaffOnly() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("score-blocks"))
        let scoreNode = try #require(try score.encode().first("Score"))
        let staffBodies = scoreNode.all("Staff")
        let firstStaff = try #require(staffBodies.first { $0.attributes["id"] == "1" })
        let secondStaff = try #require(staffBodies.first { $0.attributes["id"] == "2" })

        #expect(firstStaff.children.map(\.name) == [
            "VBox", "Measure", "Measure", "HBox", "Measure",
            "TBox", "Measure", "FBox", "Measure",
        ])
        #expect(secondStaff.children.map(\.name) == [
            "Measure", "Measure", "Measure", "Measure", "Measure",
        ])
    }

    @Test func blocksAreStableAcrossDecodeEncodeDecode() throws {
        let decoded = try MSCXParser.parse(MSCXFixtureLoader.mscxData("score-blocks"))
        let encoded = try XMLTreeSerializer.serialize(decoded.encode())
        let reparsed = try MSCXParser.parse(encoded)

        #expect(reparsed.blocks == decoded.blocks)
    }

    @Test func textFrameRestoresItsUnmodeledChildren() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("score-blocks"))
        let positioned = try #require(score.blocks.first { block in
            guard case let .opaqueFrame(frame) = block.block else { return false }
            return frame.kind == .text
        })
        let encoded = positioned.block.encode()

        #expect(encoded.name == "TBox")
        #expect(encoded.children.map(\.name) == ["Text", "topMargin"])
        #expect(encoded.first("topMargin")?.text == "2")
        #expect(encoded.first("Text")?.first("text")?.text == "Interlude")
    }

    @Test func preservedMarkupOptOutKeepsOpaqueFrameElement() {
        let block = ScoreBlock.opaqueFrame(OpaqueFrame(
            kind: .horizontal,
            preservedMarkup: [PreservedXML(name: "width", text: "10")],
        ))
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false

        let encoded = block.encode(options: options)

        #expect(encoded.name == "HBox")
        #expect(encoded.children.isEmpty)
    }

    @Test func strippingPreservedMarkupClearsBothFrameBags() {
        let score = Score(
            division: 480,
            blocks: [
                PositionedScoreBlock(
                    beforeMeasureIndex: 0,
                    block: .verticalFrame(ScoreFrame(
                        heightSp: 10,
                        texts: [],
                        preservedMarkup: [PreservedXML(name: "bottomGap")],
                    )),
                ),
                PositionedScoreBlock(
                    beforeMeasureIndex: 1,
                    block: .opaqueFrame(OpaqueFrame(
                        kind: .fret,
                        preservedMarkup: [PreservedXML(name: "fretFrameTextScale")],
                    )),
                ),
            ],
        )

        let stripped = score.strippingPreservedMarkup()

        if case let .verticalFrame(frame) = stripped.blocks[0].block {
            #expect(frame.preservedMarkup.isEmpty)
        } else {
            Issue.record("expected a vertical frame")
        }
        if case let .opaqueFrame(frame) = stripped.blocks[1].block {
            #expect(frame.preservedMarkup.isEmpty)
        } else {
            Issue.record("expected an opaque frame")
        }
    }

    // MARK: - Typed TBox / HBox / picture carriers

    private func positioned(_ index: Int, _ block: ScoreBlock) -> PositionedScoreBlock {
        PositionedScoreBlock(beforeMeasureIndex: index, block: block)
    }

    private func pageBreak() -> PreservedXML {
        PreservedXML(name: "LayoutBreak", children: [PreservedXML(name: "subtype", text: "page")])
    }

    @Test func frameStreamSkipsOnlyTheTitleBlock() {
        let title = positioned(0, .verticalFrame(ScoreFrame(heightSp: 10, texts: [])))
        let box = positioned(0, .textFrame(TextFrame()))
        let later = positioned(4, .verticalFrame(ScoreFrame(heightSp: 6, texts: [])))
        let score = Score(division: 480, blocks: [title, box, later])

        #expect(score.frameStream == [box, later])
    }

    @Test func frameStreamTreatsTheFirstLeadingVBoxAsTheTitle() {
        let box = positioned(0, .textFrame(TextFrame()))
        let title = positioned(0, .verticalFrame(ScoreFrame(heightSp: 10, texts: [])))
        let score = Score(division: 480, blocks: [box, title])

        #expect(score.frameStream == [box])
    }

    @Test func frameStreamIsEmptyWithoutBlocksAndWithOnlyATitle() {
        let title = positioned(0, .verticalFrame(ScoreFrame(heightSp: 10, texts: [])))

        #expect(Score(division: 480).frameStream.isEmpty)
        #expect(Score(division: 480, blocks: [title]).frameStream.isEmpty)
    }

    @Test func carrierDefaultsMatchMuseScore() {
        let margins = FrameMargins()
        let image = FrameImage(path: "a.png")
        let frame = ScoreFrame(heightSp: 10, texts: [])

        #expect(margins == FrameMargins(left: 0, right: 0, top: 0, bottom: 0))
        #expect(image.autoScale == false)
        #expect(image.lockAspectRatio == true)
        #expect(image.sizeIsSpatium == true)
        #expect(image.size == nil)
        #expect(image.offsetSp == nil)
        #expect(frame.autoSize == nil)
        #expect(frame.topGapSp == nil)
        #expect(frame.bottomGapSp == nil)
        #expect(frame.images.isEmpty)
        #expect(TextFrame().margins == FrameMargins())
        #expect(HorizontalFrame().widthSp == nil)
        #expect(Score(division: 480).pictures.isEmpty)
    }

    @Test func scoreFrameEqualityAndHashIncludeTheGap() {
        let plain = ScoreFrame(heightSp: 10, texts: [])
        let gapped = ScoreFrame(heightSp: 10, texts: [], topGapSp: 4)

        #expect(plain != gapped)
        #expect(plain.hashValue != gapped.hashValue)
    }

    @Test func scoreFrameHashIncludesTheBottomGapAndAutoSize() {
        let plain = ScoreFrame(heightSp: 10, texts: [])

        #expect(plain.hashValue != ScoreFrame(heightSp: 10, texts: [], bottomGapSp: 5).hashValue)
        #expect(plain.hashValue != ScoreFrame(heightSp: 10, texts: [], autoSize: false).hashValue)
    }

    @Test func pageBreakAfterReadsAPreservedPageBreak() {
        #expect(ScoreFrame(heightSp: 6, texts: [], preservedMarkup: [pageBreak()]).pageBreakAfter)
        #expect(TextFrame(preservedMarkup: [pageBreak()]).pageBreakAfter)
    }

    @Test func pageBreakAfterIsFalseForALineBreakAndForNoBreak() {
        let lineBreak = PreservedXML(name: "LayoutBreak", children: [PreservedXML(name: "subtype", text: "line")])

        #expect(!ScoreFrame(heightSp: 6, texts: [], preservedMarkup: [lineBreak]).pageBreakAfter)
        #expect(!TextFrame(preservedMarkup: [lineBreak]).pageBreakAfter)
        #expect(!ScoreFrame(heightSp: 6, texts: []).pageBreakAfter)
        #expect(!TextFrame().pageBreakAfter)
    }

    @Test func strippingPreservedMarkupClearsTheTypedBoxBags() {
        let marked = FrameText(
            style: .other,
            text: "x",
            preservedTextMarkup: PreservedTextMarkup(content: [.characters("x")], derivedText: "x"),
        )
        let score = Score(
            division: 480,
            blocks: [
                positioned(0, .verticalFrame(ScoreFrame(
                    heightSp: 10,
                    texts: [marked],
                    preservedMarkup: [PreservedXML(name: "a")],
                    images: [FrameImage(path: "p.png", preservedMarkup: [PreservedXML(name: "b")])],
                ))),
                positioned(1, .textFrame(TextFrame(text: marked, preservedMarkup: [PreservedXML(name: "c")]))),
                positioned(2, .horizontalFrame(HorizontalFrame(preservedMarkup: [PreservedXML(name: "d")]))),
            ],
        )

        let stripped = score.strippingPreservedMarkup()

        #expect(stripped.blocks[0].block == .verticalFrame(ScoreFrame(
            heightSp: 10,
            texts: [FrameText(style: .other, text: "x")],
            images: [FrameImage(path: "p.png")],
        )))
        #expect(stripped.blocks[1].block == .textFrame(TextFrame(text: FrameText(style: .other, text: "x"))))
        #expect(stripped.blocks[2].block == .horizontalFrame(HorizontalFrame()))
    }
}
