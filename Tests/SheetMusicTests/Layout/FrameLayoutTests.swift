#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    /// See `TitleBlockAlignTests`: anchor to SheetMusicLayout's own `CGFloat` off Apple.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// The frame builder: a `<VBox>` or `<TBox>` after the title, as layout geometry, and the engine's frame stream (the
/// frames between systems and the title's pictures). Text-dependent numbers are relations; geometry that touches no
/// text is asserted in exact sp multiples.
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

    @Test("a picture whose written offset or size is not a finite number lays out nothing")
    func nonFiniteImageGeometryIsDropped() {
        let images = [
            FrameImage(path: "a.png", size: CGSize(width: 12, height: 6), offsetSp: CGPoint(x: CGFloat.nan, y: 0)),
            FrameImage(path: "a.png", size: CGSize(width: CGFloat.infinity, height: 6)),
        ]
        let source = ScoreFrame(heightSp: 6, texts: [], images: images)
        let placed = LayoutEngine.layoutImages(
            of: source, pictures: ["a.png": pngHeader(width: 40, height: 20)], docWidth: 200, fitHeight: 60, sp: 10,
        )
        #expect(placed.isEmpty)
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

    // MARK: - The engine's frame stream

    private func load(_ name: String) throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
    }

    private func loadPictures() throws -> Score {
        try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures"))
    }

    /// `score` with every block but its title block removed.
    private func titleOnly(_ score: Score) -> Score {
        var stripped = score
        stripped.blocks = []
        stripped.titleFrame = score.titleFrame
        return stripped
    }

    /// One treble staff of `measures` measure rests under a "Song" title block.
    private func blankScore(measures: Int) -> Score {
        let part = BlankScoreTemplate.PartPlan(
            instrumentID: "piano", staves: [BlankScoreTemplate.StaffPlan(clefType: "G")],
        )
        return Score.blank(BlankScoreTemplate(title: "Song", parts: [part], measureCount: measures))
    }

    /// `score` laid out at 700 pt (wrapped unless `options` says otherwise).
    private func laidOut(_ score: Score, options: ScoreViewOptions = ScoreViewOptions()) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: options, availableWidth: 700)
    }

    /// The systems on either side of a break before measure `boundary`: the one that ends with `boundary - 1` and the
    /// one after it, which starts with `boundary`. Fails when no system starts at `boundary`.
    @discardableResult
    private func systemsAround(
        _ boundary: Int, in document: LayoutDocument,
    ) throws -> (above: LayoutSystem, below: LayoutSystem) {
        let index = document.systems.firstIndex { $0.measures.first?.measureIndex == boundary }
        let below = try #require(index, "no system starts at measure \(boundary)")
        try #require(below > 0)
        let above = document.systems[below - 1]
        #expect(above.measures.last?.measureIndex == boundary - 1)
        return (above, document.systems[below])
    }

    @Test("a score with only its title block lays out no frame and keeps the title-to-system rule")
    func titleOnlyScoreIsUnchanged() throws {
        let score = try titleOnly(load("score-blocks"))
        let margins = EngravingMargins(top: 3, leading: 2)
        let document = laidOut(score, options: ScoreViewOptions(spacing: EngravingSpacing(margins: margins)))
        let title = try #require(document.titleFrame)
        let first = try #require(document.systems.first)
        #expect(document.frames.isEmpty)
        #expect(document.titleImages.isEmpty)
        #expect(first.origin.y == title.height + document.metrics.sp * margins.top)
    }

    @Test("the boxes after the title are frames in score order, and a frame between measures ends a system")
    func framesAreInOrderAndForceBreaks() throws {
        let document = try laidOut(load("frames-boxes"))
        #expect(document.frames.map(\.kind) == [.vertical, .text, .vertical])
        #expect(document.frames.map(\.beforeMeasureIndex) == [4, 8, 12])
        for boundary in [4, 8] {
            try systemsAround(boundary, in: document)
        }
    }

    @Test("a frame sits its top gap below the system above and its bottom gap above the system below")
    func distancesFollowTheRule() throws {
        let document = try laidOut(load("frames-boxes"))
        let sp = document.metrics.sp
        let match = document.frames.first { $0.beforeMeasureIndex == 4 }
        let frame = try #require(match)
        let around = try systemsAround(4, in: document)
        #expect(closeEnough(frame.originY - (around.above.origin.y + around.above.size.height), 4 * sp))
        #expect(closeEnough(around.below.origin.y - frame.bottom, 5 * sp))
    }

    @Test("a text frame without gaps sits 7 sp from the systems on either side")
    func defaultGapsAreSevenSp() throws {
        let document = try laidOut(load("frames-boxes"))
        let sp = document.metrics.sp
        let match = document.frames.first { $0.kind == .text }
        let frame = try #require(match)
        let around = try systemsAround(8, in: document)
        #expect(frame.beforeMeasureIndex == 8)
        #expect(closeEnough(frame.originY - (around.above.origin.y + around.above.size.height), 7 * sp))
        #expect(closeEnough(around.below.origin.y - frame.bottom, 7 * sp))
    }

    @Test("a frame after the last measure sits 7 sp below the last system and the document grows to hold it")
    func trailingFrameExtendsTheDocument() throws {
        let document = try laidOut(load("frames-boxes"))
        let frame = try #require(document.frames.last)
        let last = try #require(document.systems.last)
        #expect(frame.beforeMeasureIndex == 12)
        #expect(closeEnough(frame.originY - (last.origin.y + last.size.height), 7 * document.metrics.sp))
        #expect(document.size.height >= frame.bottom)
    }

    @Test("horizontal mode lays out no frame and as many systems as the score without its boxes")
    func bareHorizontalModeHasNoFrames() throws {
        let score = try load("frames-boxes")
        let options = ScoreViewOptions(wrapToViewWidth: false)
        let document = laidOut(score, options: options)
        let bare = laidOut(titleOnly(score), options: options)
        #expect(document.frames.isEmpty)
        #expect(document.systems.count == bare.systems.count)
    }

    @Test("every measure still appears exactly once across the systems")
    func systemsAreStillIndexedBySystems() throws {
        let document = try laidOut(load("frames-boxes"))
        #expect(document.systems.flatMap(\.measures).map(\.measureIndex) == Array(0 ... 11))
    }

    @Test("a frame ends the system before it even when the policy ignores every authored break")
    func frameBreakIgnoresTheBreakPolicy() throws {
        let document = try laidOut(load("frames-boxes"), options: ScoreViewOptions(breakPolicy: .ignoreAll))
        #expect(document.frames.map(\.beforeMeasureIndex) == [4, 8, 12])
        for boundary in [4, 8] {
            try systemsAround(boundary, in: document)
        }
    }

    @Test("the title's picture lands in titleImages and a later box keeps its own")
    func titlePicturesLandInTitleImages() throws {
        let document = try laidOut(loadPictures())
        let title = try #require(document.titleFrame)
        let picture = try #require(document.titleImages.first)
        let frame = try #require(document.frames.first)
        #expect(document.titleImages.count == 1)
        #expect(picture.format == .png)
        #expect(picture.rect.maxY <= title.height + 0.01)
        #expect(document.frames.count == 1)
        #expect(frame.kind == .vertical)
        #expect(frame.beforeMeasureIndex == 2)
        #expect(frame.images.map(\.format) == [.jpeg])
    }

    @Test("horizontal mode still lays out the title's picture, and no frame")
    func titlePicturesAlsoInHorizontalMode() throws {
        let document = try laidOut(loadPictures(), options: ScoreViewOptions(wrapToViewWidth: false))
        #expect(document.titleImages.count == 1)
        #expect(document.frames.isEmpty)
    }

    @Test("a text frame before measure 0 sits 7 sp below the title block and 7 sp above the first system")
    func frameAtIndexZeroSitsBetweenTitleAndFirstSystem() throws {
        var score = blankScore(measures: 2)
        score.blocks.append(PositionedScoreBlock(beforeMeasureIndex: 0, block: textFrame("Intro")))
        let margins = EngravingMargins(top: 3)
        let document = laidOut(score, options: ScoreViewOptions(spacing: EngravingSpacing(margins: margins)))
        let sp = document.metrics.sp
        let title = try #require(document.titleFrame)
        let frame = try #require(document.frames.first)
        let first = try #require(document.systems.first)
        #expect(frame.kind == .text)
        #expect(frame.beforeMeasureIndex == 0)
        #expect(closeEnough(frame.originY, margins.top * sp + title.height + 7 * sp))
        #expect(closeEnough(first.origin.y - frame.bottom, 7 * sp))
    }

    @Test("the title block grows to a fixed-size picture taller than its height, and system 0 stays below it")
    func titleGrowsToATallPicture() throws {
        var score = blankScore(measures: 2)
        let image = FrameImage(path: "tall.png", size: CGSize(width: 8, height: 16))
        score.titleFrame = ScoreFrame(heightSp: 10, texts: [FrameText(style: .title, text: "Song")], images: [image])
        score.pictures = ["tall.png": pngHeader(width: 40, height: 80)]
        let document = laidOut(score)
        let title = try #require(document.titleFrame)
        let picture = try #require(document.titleImages.first)
        let first = try #require(document.systems.first)
        #expect(title.height >= 16 * document.metrics.sp)
        #expect(first.origin.y == title.height)
        #expect(picture.rect.maxY <= first.origin.y + 0.01)
    }

    /// Twenty single-staff measures of whole-measure rests under a title, except a note in measure 15, so collapsing
    /// multi-measure rests gives the runs `0 ..< 15` and `16 ..< 20`.
    private func restsAroundANote(blocks: [PositionedScoreBlock]) -> Score {
        let rest = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let chord = Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])
        var measures = Array(repeating: rest, count: 20)
        measures[15] = Measure(voices: [Voice(elements: [.chord(chord)])])
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])],
            systemMeasures: IdentifiedArray(Array(repeating: SystemMeasure(), count: 20)),
            titleFrame: ScoreFrame(heightSp: 10, texts: [FrameText(style: .title, text: "Rests")]),
            blocks: blocks,
        )
    }

    @Test("a frame right after a collapsed rest run ends the system and sits between the two systems")
    func frameAfterACollapsedRestEndsTheSystem() throws {
        let tbox = PositionedScoreBlock(beforeMeasureIndex: 15, block: textFrame("Interlude"))
        let options = ScoreViewOptions(multiMeasureRest: .collapse(minimumMeasures: 2))
        let document = laidOut(restsAroundANote(blocks: [tbox]), options: options)
        #expect(document.systems.flatMap(\.measures).compactMap(\.multiMeasureRest) == [15, 4])
        let index = document.systems.firstIndex { $0.measures.first?.measureIndex == 15 }
        let below = try #require(index, "no system starts at measure 15")
        try #require(below > 0)
        let above = document.systems[below - 1]
        let frame = try #require(document.frames.first)
        #expect(frame.beforeMeasureIndex == 15)
        #expect(frame.originY >= above.origin.y + above.size.height)
        #expect(frame.bottom <= document.systems[below].origin.y)
    }
}
