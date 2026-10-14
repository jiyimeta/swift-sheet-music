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
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// Layout attaches each formatted element's runs and measures it by them: placement, ink, skyline and the vertical
/// extent all read the same `LayoutRichText`. Numbers are hand-derived against the stub provider (advance per
/// character: lowercase 0.5 em, uppercase 0.65, space and punctuation 0.3, anything else 0.55; ascent 0.85 em, descent
/// 0.25 em, no leading; ink spans each non-blank run's advance over `-descent ... ascent`). At `staffSize: 20` the
/// spatium is 5 pt, so a spatium-dependent style's `<font size>` is literal points.
@Suite("Rich text in layout")
struct RichTextLayoutTests {
    private static let metrics = StaffMetrics(staffSize: 20)
    private static let plain = RichTextFormat()

    /// Tests that run `LayoutEngine.layout` use the installed provider (`LayoutEngine.layout` asserts it is not the
    /// stub on a CoreText platform), so they assert relations, not constants.
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Hand-built elements and `LayoutRichText`s only: never call `LayoutEngine.layout` inside.
    private static func stub<T>(_ body: () throws -> T) rethrows -> T {
        try FontMetrics.$scopedProvider.withValue(StubFontMetricsProvider(), operation: body)
    }

    /// The installed provider; the closure is only a scope that keeps the test bodies uniform.
    private static func installed<T>(_ body: () throws -> T) rethrows -> T {
        try body()
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 1e-6
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        close(a.minX, b.minX) && close(a.minY, b.minY) && close(a.width, b.width) && close(a.height, b.height)
    }

    private static func fixtureDocument() throws -> LayoutDocument {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("rich-text"))
        return LayoutEngine.layout(
            score: score, options: ScoreViewOptions(includeTitleFrame: true), availableWidth: 1200,
        )
    }

    private static func elements(_ document: LayoutDocument) -> [LayoutElement] {
        document.systems.flatMap(\.measures).flatMap { $0.elements + $0.markers + $0.jumps }
    }

    private static func staffTexts(_ document: LayoutDocument) -> [(text: String, rich: LayoutRichText?)] {
        elements(document).compactMap { element in
            guard case let .staffText(text, _, _, _, _, _, _, _, rich) = element else { return nil }
            return (text, rich)
        }
    }

    /// A one-staff score with a single staff text over a whole-note chord.
    private static func score(staffText: StaffText) -> Score {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
        let lane = PositionedSystemElement(
            position: .start, element: .staffText(staffText), originalStaff: staff,
        )
        return Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
        )], systemMeasures: [SystemMeasure(elements: [lane])])
    }

    @Test("every formatted element of the fixture reaches the document with its runs")
    func everyFormattedElementCarriesRuns() throws {
        try Self.installed {
            let document = try Self.fixtureDocument()
            let elements = Self.elements(document)
            let rich = Set(Self.staffTexts(document).filter { $0.rich != nil }.map(\.text))
            #expect(rich == ["poco a poco\ncresc.", "Solo ad lib.", "senza ", "under, strike, H2O"])
            #expect(elements.contains { element in
                if case .rehearsalMark(_, _, _, _, _, _, _, .some) = element { true } else { false }
            })
            #expect(elements.contains { element in
                if case .marker(_, _, _, _, .some) = element { true } else { false }
            })
            #expect(elements.contains { element in
                if case .jump(_, _, _, .some) = element { true } else { false }
            })
            #expect(elements.contains { element in
                if case .textMark(.lyrics, _, _, .some) = element { true } else { false }
            })
            let frame = try #require(document.titleFrame)
            #expect(!frame.texts.isEmpty && frame.texts.allSatisfy { $0.richText != nil })
        }
    }

    @Test("ink and skyline of a staff text with a symbol run are measured from the runs, not the plain text")
    func staffTextInkAndSkylineFollowRuns() throws {
        try Self.installed {
            let document = try Self.fixtureDocument()
            let element = try #require(Self.elements(document).first { element in
                if case .staffText("senza ", _, _, _, _, _, _, _, .some) = element { true } else { false }
            })
            guard case let .staffText(_, origin, _, _, _, _, _, _, rich?) = element else { return }
            // "senza " (text run) then the Ped glyph (symbol run): the second run is what plain text misses.
            #expect(rich.lines.count == 1 && rich.lines[0].runs.count == 2)
            let textRun = rich.lines[0].runs[0]
            let textAdvance = textRun.advance
            #expect(rich.lines[0].runs[1].advance > 0)

            // The ink is the runs' own (anchor (0, 1): left edge at origin.x), and reaches past the text run's ink.
            let ink = try #require(TextInkGeometry.rects(for: element, metrics: document.metrics)?.first)
            let expected = try #require(rich.inkRect(at: origin, anchor: CGPoint(x: 0, y: 1)))
            #expect(Self.close(ink.minX, origin.x))
            #expect(Self.close(ink.minX, expected.minX) && Self.close(ink.width, expected.width))
            #expect(Self.close(ink.minY, expected.minY) && Self.close(ink.height, expected.height))
            let textInk = try #require(FontMetrics.provider.textInkBounds(text: "senza ", font: textRun.font))
            #expect(ink.width > textInk.width + 1e-6)

            let sky = try #require(
                LayoutElementShape.autoplacedRects(for: element, kind: .staffText, metrics: document.metrics).first,
            )
            #expect(Self.close(sky.width, rich.size.width))
            #expect(sky.width > textAdvance + 1e-6)
        }
    }

    /// The plan's `elementYPoints(...).count == 2` also holds on the plain path (a "\n" in the text is enough), so it
    /// pins nothing. Here the second line is set 20 pt in a 10 pt text: the stack is 33 pt tall, not the plain 22.
    /// Line 1: ascent 8.5, descent 2.5. Line 2: ascent 17, descent 5. Baselines 8.5 and 8.5 + 2.5 + 0 + 17 = 28, so the
    /// height is 28 + 5 = 33 and the extent below the first line is 33 - 8.5 - 2.5 = 22 (plain: 22 - 11 = 11).
    @Test("a stack's vertical extent is the runs' height, not the plain text's")
    func stackHeightFollowsRuns() {
        Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.text("A", Self.plain)], [.text("B", RichTextFormat(size: 20))]]),
                style: .staffText, metrics: Self.metrics,
            )
            #expect(Self.close(rich.size.height, 33))
            let element = LayoutElement.staffText(
                text: "A\nB", origin: CGPoint(x: 0, y: 0), color: nil, style: .staffText, anchor: nil,
                richText: rich,
            )
            let ys = LayoutEngine.elementYPoints(element, sp: Self.metrics.sp)
            #expect(ys.count == 2)
            #expect(Self.close(ys[0], 0) && Self.close(ys[1], -22))
        }
    }

    /// A rehearsal mark "A" set 30 pt. Advance 0.65 × 30 = 19.5; ascent 25.5, descent 7.5, so the block is 19.5 × 33
    /// and its ink (0, 0, 19.5, 33). Pad = 0.5 sp = 2.5. The ink is placed bottom-leading at (origin.x + 2.5,
    /// origin.y - 2.5) = (102.5, 47.5): block top-left (102.5, 14.5). The frame box is
    /// (100, 50 - 2 × 2.5 - 33 = 12, 19.5 + 5 = 24.5, 33 + 5 = 38), grown by half the 0.8 pt stroke on each side:
    /// (99.6, 11.6, 25.3, 38.8). The plain 14 pt "A" would be 9.1 wide.
    @Test("a rehearsal mark's ink and frame are measured from the runs")
    func rehearsalMarkFollowsRuns() throws {
        try Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.text("A", RichTextFormat(size: 30))]]),
                style: .rehearsalMark, metrics: Self.metrics,
            )
            let element = LayoutElement.rehearsalMark(
                text: "A", origin: CGPoint(x: 100, y: 50), frame: .rectangle, color: nil, measureIndex: 0,
                richText: rich,
            )
            let rects = try #require(TextInkGeometry.rects(for: element, metrics: Self.metrics))
            #expect(rects.count == 2)
            let ink = rects[0]
            #expect(Self.close(ink.minX, 102.5) && Self.close(ink.minY, 14.5))
            #expect(Self.close(ink.width, 19.5) && Self.close(ink.height, 33))
            let frame = rects[1]
            #expect(Self.close(frame.minX, 99.6) && Self.close(frame.minY, 11.6))
            #expect(Self.close(frame.width, 25.3) && Self.close(frame.height, 38.8))

            let sky = try #require(
                LayoutElementShape.autoplacedRects(for: element, kind: .rehearsalMark, metrics: Self.metrics).first,
            )
            #expect(Self.close(sky.width, 25.3) && Self.close(sky.height, 38.8))
        }
    }

    /// A "Fine" with the run set 40 pt: advance (0.65 + 0.5 + 0.5 + 0.5) × 40 = 86, ascent 34, descent 10, so the block
    /// is 86 × 44 with ink (0, 0, 86, 44). A jump's and a left marker's ink is that block hung off the origin by the
    /// anchor their kind is drawn at.
    @Test("a jump's and a marker's ink is their runs' ink placed by their kind's anchor")
    func navigationInkFollowsRuns() throws {
        try Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.text("Fine", RichTextFormat(size: 40))]]),
                style: .repeatRight, metrics: Self.metrics,
            )
            let origin = CGPoint(x: 40, y: 20)
            let cases: [(LayoutElement, LayoutRichText.ElementKind)] = [
                (.jump(text: "Fine", origin: origin, richText: rich), .jump),
                (.marker(kind: .user, text: "Fine", origin: origin, richText: rich), .marker),
            ]
            for (element, kind) in cases {
                let anchor = LayoutRichText.anchor(for: kind)
                let ink = try #require(TextInkGeometry.rects(for: element, metrics: Self.metrics)?.first)
                #expect(Self.close(ink.minX, 40 - anchor.x * 86) && Self.close(ink.minY, 20 - anchor.y * 44))
                #expect(Self.close(ink.width, 86) && Self.close(ink.height, 44))
            }
        }
    }

    /// A lyric "Ah" set 40 pt. Advance (0.65 + 0.5) × 40 = 46, block 46 × 44, ink (0, 0, 46, 44). A lyric is centered
    /// on its origin ((0.5, 0.5)): top-left (30 - 23, 15 - 22) = (7, -7).
    @Test("a lyric's ink is the runs' ink centered on the origin")
    func lyricInkFollowsRuns() throws {
        try Self.stub {
            let rich = LayoutRichText(
                RichText(lines: [[.text("Ah", RichTextFormat(size: 40))]]),
                style: .lyricsOdd, metrics: Self.metrics,
            )
            let element = LayoutElement.textMark(
                kind: .lyrics(), text: "Ah", origin: CGPoint(x: 30, y: 15), richText: rich,
            )
            let ink = try #require(TextInkGeometry.rects(for: element, metrics: Self.metrics)?.first)
            #expect(Self.close(ink.minX, 7) && Self.close(ink.minY, -7))
            #expect(Self.close(ink.width, 46) && Self.close(ink.height, 44))
        }
    }

    /// Review Focus 2. The control half proves the markup does reach layout when the text is unedited, so the edited
    /// half cannot pass merely because nothing ever carries runs.
    @Test("text edited away from its markup lays out plain")
    func editedTextIsPlain() {
        Self.installed {
            let markup = PreservedTextMarkup(
                content: [.element(.init(name: "b", content: [.characters("Solo")]))], derivedText: "Solo",
            )
            let unedited = LayoutEngine.layout(
                score: Self.score(staffText: StaffText(text: "Solo", preservedTextMarkup: markup)),
                options: ScoreViewOptions(), availableWidth: 800,
            )
            let control = Self.staffTexts(unedited)
            #expect(control.map(\.text) == ["Solo"])
            #expect(control.allSatisfy { $0.rich != nil })

            let edited = LayoutEngine.layout(
                score: Self.score(staffText: StaffText(text: "Tutti", preservedTextMarkup: markup)),
                options: ScoreViewOptions(), availableWidth: 800,
            )
            let texts = Self.staffTexts(edited)
            #expect(texts.map(\.text) == ["Tutti"])
            #expect(texts.allSatisfy { $0.rich == nil })
        }
    }

    /// The rich lines against their plain twin: the same entries without runs, placed by the plain path. The title and
    /// subtitle hang from their top edges in the block's face, so every one of their lines lands where its twin does —
    /// the subtitle's second line too, stepped by its unformatted first line's own metrics. (The composer is italic and
    /// bottom-anchored, so it rises by its italic line's height, which need not equal the plain line height.)
    @Test("a rich title line is placed where its plain twin is; a broken subtitle is two placed lines")
    func titleLines() throws {
        try Self.installed {
            let document = try Self.fixtureDocument()
            let frame = try #require(document.titleFrame)
            let lines = frame.placedLines()
            let plainTexts = frame.texts.map { text in
                LayoutFrameText(
                    text: text.text, style: text.style, position: text.position, fontSize: text.fontSize,
                    anchor: text.anchor,
                )
            }
            let twin = LayoutTitleFrame(height: frame.height, texts: plainTexts).placedLines()
            #expect(lines.map(\.text) == twin.map(\.text))
            for (rich, plain) in zip(lines, twin) where rich.entryIndex < 2 {
                #expect(Self.close(rich.position.x, plain.position.x) && Self.close(rich.position.y, plain.position.y))
            }
            let title = try #require(lines.first { $0.entryIndex == 0 })
            #expect(title.richLine?.runs.map(\.font.weight) == [.bold])
            #expect(title.positionedRuns.count == 1)
            #expect(title.decorations.isEmpty)
            // The bold run's advance is centered on the twin's anchor, as the title style centers the plain line.
            let line = try #require(title.richLine)
            let run = try #require(title.positionedRuns.first)
            let plainTitle = try #require(twin.first { $0.entryIndex == 0 })
            #expect(plainTitle.horizontalAnchor == 0.5)
            #expect(Self.close(run.baseline.x + line.width / 2, plainTitle.position.x))

            let subtitle = lines.filter { $0.entryIndex == 1 }
            #expect(subtitle.map(\.text) == ["First line", "arr. Second"])
            #expect(subtitle.allSatisfy { $0.richLine != nil })
            // An unformatted run sits on its twin's baseline: one ascent of the block's face below the line's top.
            let plainSubtitle = try #require(twin.first { $0.entryIndex == 1 })
            let face = FontMetrics.provider.renderingTextFont(LayoutTitleFrame.font(size: plainSubtitle.fontSize))
            let subtitleRun = try #require(subtitle.first?.positionedRuns.first)
            let plainBaseline = plainSubtitle.position.y + FontMetrics.provider.ascent(font: face)
            #expect(Self.close(subtitleRun.baseline.y, plainBaseline))
        }
    }

    /// Each line's top edge of a three-line 10 pt title entry `One / Two / Three` positioned at `y`.
    private static func titleTops(_ anchor: LayoutFrameText.Anchor, y: CGFloat, rich: LayoutRichText?) -> [CGFloat] {
        LayoutTitleFrame(height: 100, texts: [LayoutFrameText(
            text: "One\nTwo\nThree", style: .subtitle, position: CGPoint(x: 0, y: y), fontSize: 10, anchor: anchor,
            richText: rich,
        )]).placedLines().map(\.position.y)
    }

    /// The middle line set at twice the block's 10 pt. Stub: the block face's ascent and descent are 8.5 and 2.5, and
    /// a plain line steps `lineHeight(fontSize: 10)` = 12, a gap of 1 below its descent. The 20 pt line's ascent and
    /// descent are 17 and 5, so it steps 17 + 5 + 1 = 23: tops 0, 12, 35, where the plain 0, 12, 24 would start the
    /// third line above the large line's own baseline (12 + 17 = 29). Bottom-anchored at 100, the block rises by
    /// 12 + 23 + 12 = 47 to 53, 65, 88; the plain block by 3 × 12 = 36 to 64, 76, 88.
    @Test("a title line set larger pushes the next line down by its own height")
    func richTitleLineSteps() {
        Self.stub {
            let lines: [[RichTextRun]] = [
                [.text("One", Self.plain)], [.text("Two", RichTextFormat(size: 20))], [.text("Three", Self.plain)],
            ]
            let rich = LayoutRichText(
                RichText(lines: lines), baseFont: LayoutTitleFrame.font(size: 10), pointScale: 1, symbolPointSize: 10,
            )
            let cases: [(LayoutFrameText.Anchor, CGFloat, LayoutRichText?, [CGFloat])] = [
                (.topLeading, 0, nil, [0, 12, 24]), (.topLeading, 0, rich, [0, 12, 35]),
                (.bottomLeading, 100, nil, [64, 76, 88]), (.bottomLeading, 100, rich, [53, 65, 88]),
            ]
            for (anchor, y, runs, expected) in cases {
                let tops = Self.titleTops(anchor, y: y, rich: runs)
                #expect(tops.count == 3 && zip(tops, expected).allSatisfy { Self.close($0, $1) }, "\(tops)")
            }
        }
    }

    /// Installed provider: a title entry whose runs are all in the block face steps exactly like the plain entry. A
    /// rich line steps its own ascent + descent + (lineHeight - face ascent - face descent), which is lineHeight when
    /// its metrics are the face's; the runs are typeset in `renderingTextFont` of the block face, as the engine does.
    @Test("a title entry in the block's face steps exactly like its plain twin")
    func blockFaceTitleLineStepsMatchPlain() {
        Self.installed {
            let face = FontMetrics.provider.renderingTextFont(LayoutTitleFrame.font(size: 10))
            let lines: [[RichTextRun]] = ["One", "Two", "Three"].map { [.text($0, Self.plain)] }
            let rich = LayoutRichText(RichText(lines: lines), baseFont: face, pointScale: 1, symbolPointSize: 10)
            for (anchor, y) in [(LayoutFrameText.Anchor.topLeading, CGFloat(0)), (.bottomLeading, 100)] {
                let plain = Self.titleTops(anchor, y: y, rich: nil)
                let tops = Self.titleTops(anchor, y: y, rich: rich)
                #expect(tops.count == 3 && plain.count == 3)
                #expect(zip(tops, plain).allSatisfy { Self.close($0, $1) }, "\(anchor): \(tops) vs \(plain)")
            }
        }
    }

    /// A one-run, one-font block reserves exactly its plain twin's box at every anchor in use: bottom-leading (staff
    /// text), leading-center (markers, jumps) and center (lyrics). "mo" inks inside its advance box, so the ink the
    /// rich box takes in adds nothing. A marker's or jump's plain box is measured in Edwin while its runs are set in
    /// the label face, so leading-center is compared on the shape itself; staff text and lyrics on their elements too.
    /// It passes because "mo" is upright and inks inside its advance; an italic face's overhang can make a rich box
    /// slightly wider than its plain twin, by design (the box is unioned with the runs' ink).
    @Test("a one-font rich block reserves its plain twin's box at every anchor")
    func oneFontBoxMatchesPlain() {
        Self.installed {
            let origin = CGPoint(x: 40, y: 30)
            let text = RichText(lines: [[.text("mo", Self.plain)]])
            let lyric = LayoutRichText(text, style: .lyricsOdd, metrics: Self.metrics)
            let font = TextInkGeometry.font(for: .lyricsOdd, metrics: Self.metrics)
            let kinds: [(TextAnchorConvention, LayoutRichText.ElementKind)] = [
                (.bottomLeading, .staffText), (.leadingCenter, .jump), (.center, .lyric),
            ]
            for (anchor, kind) in kinds {
                let plain = LayoutElementShape.textRect(text: "mo", font: font, origin: origin, anchor: anchor)
                let rich = LayoutElementShape.textRect(rich: lyric, origin: origin, kind: kind)
                #expect(Self.same(rich, plain), "\(anchor): \(rich) vs \(plain)")
            }
            let staff = LayoutRichText(text, style: .staffText, metrics: Self.metrics)
            let staffBoxes = [nil, staff].map { runs in
                let element = LayoutElement.staffText(
                    text: "mo", origin: origin, color: nil, style: .staffText, anchor: nil, richText: runs,
                )
                return LayoutElementShape.autoplacedRects(for: element, kind: .staffText, metrics: Self.metrics)
            }
            let lyricBoxes = [nil, lyric].map { runs in
                let element = LayoutElement.textMark(kind: .lyrics(), text: "mo", origin: origin, richText: runs)
                return LayoutElementShape.autoplacedRects(for: element, kind: .lyrics, metrics: Self.metrics)
            }
            for boxes in [staffBoxes, lyricBoxes] {
                #expect(boxes.allSatisfy { $0.count == 1 })
                #expect(zip(boxes[1], boxes[0]).allSatisfy { Self.same($0, $1) }, "\(boxes)")
            }
        }
    }
}
