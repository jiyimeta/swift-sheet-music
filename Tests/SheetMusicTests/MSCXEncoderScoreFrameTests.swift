import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

// `ScoreFrame.offsetMm` is `CGPoint`. On Apple and Android that's Foundation's own
// `CGPoint` (bare, from `import Foundation` above); WebAssembly is the only platform
// where no CoreGraphics-shaped `CGPoint` exists at all, so `SheetMusicCore` supplies
// its own — see `Sources/SheetMusicCore/Score/CGCompat+WASI.swift`. That file scopes
// itself to `os(WASI)`, not `!canImport(CoreGraphics)`, precisely because Android's
// incumbent `CGPoint` (Foundation's) must keep winning there — mirror the same gate.
#if os(WASI)
    private typealias CGPoint = SheetMusicCore.CGPoint
    private typealias CGSize = SheetMusicCore.CGSize
#endif

@Suite("MSCXEncoder ScoreFrame")
struct MSCXEncoderScoreFrameTests {
    @Test("VBox round-trips height and a Title text")
    func minimalTitleFrameRoundTrip() throws {
        let frame = ScoreFrame(
            heightSp: 10,
            texts: [FrameText(style: .title, text: "Invention")],
        )
        let xml = frame.encodeAsVBox()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        let vbox = try #require(reparsed.first("VBox"))
        let decoded = ScoreFrame.decode(vbox: vbox)
        #expect(decoded == frame)
    }

    @Test("FrameText round-trips every Style case")
    func everyFrameTextStyleRoundTrip() throws {
        let cases: [FrameText.Style] = [
            .title, .subtitle, .composer, .lyricist, .other,
        ]
        for style in cases {
            let frame = ScoreFrame(
                heightSp: 10,
                texts: [FrameText(style: style, text: "x")],
            )
            let xml = frame.encodeAsVBox()
            let bytes = XMLTreeSerializer.serialize(
                XMLTreeNode(name: "root", children: [xml]),
            )
            let reparsed = try XMLTreeParser.parse(bytes)
            let vbox = try #require(reparsed.first("VBox"))
            let decoded = ScoreFrame.decode(vbox: vbox)
            #expect(decoded.texts.first?.style == style)
        }
    }

    @Test("FrameText round-trips offsetMm")
    func frameTextOffsetRoundTrip() throws {
        let frame = ScoreFrame(
            heightSp: 12,
            texts: [
                FrameText(
                    style: .composer,
                    text: "J.S. Bach",
                    offsetMm: CGPoint(x: 0, y: 4.5),
                ),
            ],
        )
        let xml = frame.encodeAsVBox()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        let vbox = try #require(reparsed.first("VBox"))
        let decoded = ScoreFrame.decode(vbox: vbox)
        #expect(decoded == frame)
    }

    @Test("Score round-trips titleFrame on first staff")
    func scoreTitleFrameRoundTrip() throws {
        let titleFrame = ScoreFrame(
            heightSp: 10,
            texts: [
                FrameText(style: .title, text: "Invention"),
                FrameText(style: .composer, text: "J.S. Bach"),
            ],
        )
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [
                Measure(voices: [Voice(elements: [
                    .chord(Chord(
                        duration: .quarter,
                        notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                    )),
                ])]),
            ],
        )
        let part = Part(
            id: "1",
            trackName: "Voice",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        let original = Score(
            division: 480, parts: [part], titleFrame: titleFrame,
        )

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.titleFrame == titleFrame)
    }

    // MARK: - Gaps, autoSize and Image (import fidelity W7)

    private func reparsedVBox(_ frame: ScoreFrame) throws -> XMLTreeNode {
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [frame.encodeAsVBox()]))
        return try #require(XMLTreeParser.parse(bytes).first("VBox"))
    }

    @Test("a VBox with autoSize false writes boxAutoSize 0, and nil writes none")
    func autoSizeIsWrittenOnlyWhenSet() throws {
        let off = try reparsedVBox(ScoreFrame(heightSp: 6, texts: [], autoSize: false))
        let on = try reparsedVBox(ScoreFrame(heightSp: 6, texts: [], autoSize: true))
        let unset = try reparsedVBox(ScoreFrame(heightSp: 6, texts: []))

        #expect(off.first("boxAutoSize")?.text == "0")
        #expect(on.first("boxAutoSize")?.text == "1")
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(unset.first("boxAutoSize") == nil)
    }

    @Test("a written gap is written back, even one equal to the default, and nil writes none")
    func gapsAreWrittenOnlyWhenSet() throws {
        let gapped = try reparsedVBox(ScoreFrame(heightSp: 6, texts: [], topGapSp: 4, bottomGapSp: 7))
        let unset = try reparsedVBox(ScoreFrame(heightSp: 6, texts: []))

        #expect(gapped.first("topGap")?.text == "4")
        #expect(gapped.first("bottomGap")?.text == "7")
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(unset.first("topGap") == nil)
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(unset.first("bottomGap") == nil)
    }

    @Test("a VBox round-trips gaps, autoSize and an image")
    func typedVBoxFieldsRoundTrip() throws {
        let frame = ScoreFrame(
            heightSp: 8,
            texts: [FrameText(style: .title, text: "T")],
            topGapSp: 4,
            bottomGapSp: 5,
            autoSize: false,
            images: [
                FrameImage(
                    path: "a.png",
                    size: CGSize(width: 12, height: 6),
                    sizeIsSpatium: false,
                    autoScale: true,
                    lockAspectRatio: false,
                    offsetSp: CGPoint(x: 1, y: 0.5),
                ),
            ],
        )

        let decoded = try ScoreFrame.decode(vbox: reparsedVBox(frame))

        #expect(decoded == frame)
        #expect(decoded.images == frame.images)
    }

    @Test("an Image child the model does not know is written back")
    func unknownImageChildIsPreserved() throws {
        let vbox = try XMLTreeParser.parse(Data("""
        <VBox><height>10</height><Image><path>p.png</path><z>7</z></Image></VBox>
        """.utf8))
        let decoded = ScoreFrame.decode(vbox: vbox)

        let image = try reparsedVBox(decoded).first("Image")

        #expect(decoded.images.count == 1)
        #expect(decoded.images.first?.preservedMarkup.map(\.name) == ["z"])
        #expect(image?.first("path")?.text == "p.png")
        #expect(image?.first("z")?.text == "7")
    }

    @Test("a default-valued Image is written with only its path")
    func defaultImageWritesOnlyItsPath() throws {
        let node = try reparsedVBox(ScoreFrame(heightSp: 10, texts: [], images: [FrameImage(path: "a.png")]))
        let image = try #require(node.first("Image"))

        #expect(image.children.map(\.name) == ["path"])
    }

    @Test("the typed fields do not reach the VBox's preserved bag")
    func typedChildrenAreNotStoredTwice() throws {
        let vbox = try XMLTreeParser.parse(Data("""
        <VBox><height>6</height><topGap>4</topGap><bottomGap>5</bottomGap><boxAutoSize>0</boxAutoSize></VBox>
        """.utf8))

        let decoded = ScoreFrame.decode(vbox: vbox)

        #expect(decoded.preservedMarkup.isEmpty)
        #expect(decoded.topGapSp == 4)
        #expect(decoded.bottomGapSp == 5)
        #expect(decoded.autoSize == false)
    }
}
