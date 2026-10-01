import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGFloat`, so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous. File-scoped, as in every other file here.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// `.page` mode with paper margins (`LayoutBridge.PageMargins`): the Apple page deck's sheet — the score engraved into
/// the printable width, cut by the printable height, drawn inside the margins, and widened only when the music
/// overflows — and `.zero`, which has to stay the edge-to-edge page the Android and web readers draw, byte for byte.
@Suite("Page margins")
struct PageMarginsTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// `SystemSpanTests`' scores: several systems, spanners, repeats and multiple staves.
    private static let fixtures = [
        "midi01", "midi02", "midi03", "testArpeggio", "testVoltaDynamic", "testRepeatsWithKeySigs",
        "multiPartMixedStaves", "slur_ms4_resave", "spanner_offsets_score_end",
    ]

    private static let pageWidthMM = 210.0
    private static let pageHeightMM = 297.0
    private static let tenMM = LayoutBridge.PageMargins(top: 10, leading: 10, bottom: 10, trailing: 10)
    private static let mmToPt = 72.0 / 25.4
    private static let ptToMM = 25.4 / 72.0
    private static let epsilon = 1e-6

    // MARK: - Zero margins

    @Test("zero margins give today's edge-to-edge pages, byte for byte", arguments: fixtures)
    func zeroMarginsAreTheEdgeToEdgePages(fixture: String) throws {
        let score = try Self.load(fixture)
        let explicit = Self.pages(score, margins: .zero)
        let defaulted = LayoutBridge.computePages(
            score: score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM, options: Self.options(.page),
        )
        let frozen = Self.edgeToEdgePages(explicit.document)
        let explicitBytes = DrawProgramCodec.encode(pages: explicit.pages)
        let frozenBytes = DrawProgramCodec.encode(pages: frozen.pages)
        #expect(explicitBytes == frozenBytes, "\(fixture)")
        #expect(explicit.spans == frozen.spans, "\(fixture)")
        #expect(defaulted.pages == explicit.pages, "\(fixture)")
        #expect(defaulted.spans == explicit.spans, "\(fixture)")
    }

    // MARK: - With margins

    /// The whole contract in one comparison: a page with margins is the edge-to-edge page of the printable size —
    /// the same engraving, the same cuts, the same commands and spans — moved in by the leading and top margins, at the
    /// full page height and the paper width.
    @Test("margins draw the printable-size pages moved in by the leading and top margins", arguments: fixtures)
    func marginsMoveThePrintablePages(fixture: String) throws {
        let score = try Self.load(fixture)
        let margins = Self.tenMM
        let margined = Self.pages(score, margins: margins)
        let printable = LayoutBridge.computePages(
            score: score,
            pageWidthMM: Self.pageWidthMM - margins.leading - margins.trailing,
            pageHeightMM: Self.pageHeightMM - margins.top - margins.bottom,
            options: Self.options(.page),
        )
        #expect(margined.document == printable.document, "\(fixture): not engraved into the printable width")
        try #require(margined.pages.count == printable.pages.count, "\(fixture): cut at another height")
        let paperWidthMM = Self.paperWidthMM(margined.document, margins)
        for index in margined.pages.indices {
            let page = margined.pages[index]
            let moved = printable.pages[index].commands.map { $0.translated(dx: margins.leading, dy: margins.top) }
            let movedSpans = printable.spans[index].map { span in
                var span = span
                span.frameMM = span.frameMM.offsetBy(dx: margins.leading, dy: margins.top)
                return span
            }
            #expect(page.commands == moved, "\(fixture) page \(index + 1)")
            #expect(margined.spans[index] == movedSpans, "\(fixture) page \(index + 1)")
            #expect(page.heightMM == Self.pageHeightMM, "\(fixture) page \(index + 1)")
            #expect(page.widthMM == paperWidthMM, "\(fixture) page \(index + 1)")
        }
    }

    @Test("with margins every system sits inside the printable area, and no page is lost", arguments: fixtures)
    func musicStaysInsideTheMargins(fixture: String) throws {
        let score = try Self.load(fixture)
        let margins = Self.tenMM
        let margined = Self.pages(score, margins: margins)
        let edgeToEdge = Self.pages(score, margins: .zero)
        #expect(margined.pages.count >= edgeToEdge.pages.count, "\(fixture)")

        let document = margined.document
        let printableHeightMM = Self.pageHeightMM - margins.top - margins.bottom
        for (index, (page, spans)) in zip(margined.pages, margined.spans).enumerated() {
            let label = "\(fixture) page \(index + 1)"
            // Systems, not command anchors: some marks already draw a little left of a page's x = 0 without margins
            // (a glyph anchored left of its ink, under the portable metrics on Windows), and the margins move them
            // exactly as far as everything else — which the translation test above pins command by command.
            let systems = spans.compactMap(\.systemIndex)
            guard let first = systems.first else { continue }
            let pageStartY = first == 0
                ? 0
                : Double(document.systems[first - 1].origin.y + document.systems[first - 1].size.height)
            for span in spans {
                guard let systemIndex = span.systemIndex else { continue }
                let system = document.systems[systemIndex]
                let placed = DrawRect(
                    x: Double(system.origin.x) * Self.ptToMM + margins.leading,
                    y: (Double(system.origin.y) - pageStartY) * Self.ptToMM + margins.top,
                    width: Double(system.size.width) * Self.ptToMM,
                    height: Double(system.size.height) * Self.ptToMM,
                )
                #expect(placed.x >= margins.leading - Self.epsilon, "\(label) system \(systemIndex)")
                #expect(placed.y >= margins.top - Self.epsilon, "\(label) system \(systemIndex)")
                #expect(placed.maxX <= page.widthMM - margins.trailing + Self.epsilon, "\(label) system \(systemIndex)")
                // A system too tall for the printable height is given a page of its own and runs into the bottom
                // margin, as on Apple's sheets (`LayoutPaginator` always keeps a page's first system); a page holding
                // more than one system has none.
                let alone = systems.count == 1
                #expect(
                    alone || placed.maxY <= Self.pageHeightMM - margins.bottom + Self.epsilon,
                    "\(label) system \(systemIndex) ends at \(placed.maxY) of \(printableHeightMM) printable",
                )
                // The span moved with its commands: its frame still holds its system. (Not the printable area: a
                // span's frame is a conservative bound of its ink — a title line's reaches well above its baseline —
                // so it may cross into a margin where no ink does.)
                let holds = span.frameMM.x <= placed.x + Self.epsilon && span.frameMM.y <= placed.y + Self.epsilon
                    && span.frameMM.maxX >= placed.maxX - Self.epsilon
                    && span.frameMM.maxY >= placed.maxY - Self.epsilon
                #expect(holds, "\(label) system \(systemIndex): \(span.frameMM) does not hold \(placed)")
            }
        }
    }

    @Test("music wider than the printable width widens every page to it plus the side margins, and no further")
    func wideMusicWidensEveryPage() throws {
        let margins = Self.tenMM
        let wide = try ScoreBridge.loadScore(bytes: Data(Self.musicXML(measures: 160, wideMeasure: true).utf8))
        let result = Self.pages(wide, margins: margins)
        let musicRightPt = result.document.systems.map { Double($0.origin.x + $0.size.width) }.max() ?? 0
        let printableWidthPt = (Self.pageWidthMM - margins.leading - margins.trailing) * Self.mmToPt
        // Not vacuous: the 96-quarter measure has to come out wider than the line, and the widening has to be shown
        // shared by more than one page.
        try #require(musicRightPt > printableWidthPt, "the wide measure fits the line: \(musicRightPt) pt")
        try #require(result.pages.count > 1)

        let needed = musicRightPt * Self.ptToMM + margins.leading + margins.trailing
        #expect(needed > Self.pageWidthMM)
        for (index, page) in result.pages.enumerated() {
            #expect(abs(page.widthMM - needed) < 1e-9, "page \(index + 1): \(page.widthMM) mm, needed \(needed) mm")
            #expect(page.heightMM == Self.pageHeightMM, "page \(index + 1): the height never changes")
        }
        // Measured from the music's right edge, not the document's: the engine's trailing whitespace widens nothing.
        let fromDocumentWidth = Double(result.document.size.width) * Self.ptToMM + margins.leading + margins.trailing
        #expect(needed < fromDocumentWidth)

        // The same score without the wide measure keeps the page width exactly.
        let narrow = try ScoreBridge.loadScore(bytes: Data(Self.musicXML(measures: 160, wideMeasure: false).utf8))
        let widths = Set(Self.pages(narrow, margins: margins).pages.map(\.widthMM))
        #expect(widths == [Self.pageWidthMM], "music that fits leaves the page width as it is: \(widths)")
    }

    @Test("margins count only in page mode")
    func marginsOnlyInPageMode() throws {
        let score = try Self.load("midi01")
        for mode in [LayoutOptionsWire.Mode.vertical, .horizontal] {
            let margined = LayoutBridge.computePages(
                score: score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                options: Self.options(mode), margins: Self.tenMM,
            )
            let plain = LayoutBridge.computePages(
                score: score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                options: Self.options(mode),
            )
            #expect(margined.document == plain.document, "\(mode)")
            #expect(margined.pages == plain.pages, "\(mode)")
            #expect(margined.spans == plain.spans, "\(mode)")
        }
    }

    @Test("translated moves every position a command carries and none of its sizes")
    func translatedMovesPositionsOnly() {
        let cases: [(command: DrawCommand, expected: DrawCommand)] = [
            (.moveTo(x: 1, y: 2), .moveTo(x: 11, y: 7)),
            (.lineTo(x: 1, y: 2), .lineTo(x: 11, y: 7)),
            (
                .cubicTo(cx1: 1, cy1: 2, cx2: 3, cy2: 4, x: 5, y: 6),
                .cubicTo(cx1: 11, cy1: 7, cx2: 13, cy2: 9, x: 15, y: 11),
            ),
            (.fillRect(x: 1, y: 2, w: 3, h: 4), .fillRect(x: 11, y: 7, w: 3, h: 4)),
            (
                .glyph(codepoint: 0xE050, x: 1, y: 2, size: 7, fontId: .smufl),
                .glyph(codepoint: 0xE050, x: 11, y: 7, size: 7, fontId: .smufl),
            ),
            (
                .text(text: "p", x: 1, y: 2, size: 3, fontId: .textRoman),
                .text(text: "p", x: 11, y: 7, size: 3, fontId: .textRoman),
            ),
            (
                .stretchedGlyph(
                    codepoint: 0xE000, rightEdgeX: 1, topY: 2, bottomY: 30, fontSize: 7, xScale: 1.5, fontId: .smufl,
                ),
                .stretchedGlyph(
                    codepoint: 0xE000, rightEdgeX: 11, topY: 7, bottomY: 35, fontSize: 7, xScale: 1.5, fontId: .smufl,
                ),
            ),
            (.setRotation(radians: -1.5, pivotX: 1, pivotY: 2), .setRotation(radians: -1.5, pivotX: 11, pivotY: 7)),
            // The reset rotates about no point, so it stays the canonical reset.
            (.setRotation(radians: 0, pivotX: 0, pivotY: 0), .setRotation(radians: 0, pivotX: 0, pivotY: 0)),
            (.stroke(width: 0.3), .stroke(width: 0.3)),
            (.setDash(onMM: 1, offMM: 2), .setDash(onMM: 1, offMM: 2)),
            (.setColor(argb: 0xFF33_66FF), .setColor(argb: 0xFF33_66FF)),
            (.setTextStyle(flags: 1), .setTextStyle(flags: 1)),
            (.fillPath, .fillPath),
        ]
        for (command, expected) in cases {
            let moved = command.translated(dx: 10, dy: 5)
            #expect(moved == expected, "\(command)")
        }
    }

    // MARK: - Helpers

    private static func load(_ name: String) throws -> Score {
        let url = try #require(TestResources.url(forResource: name, withExtension: "mscx"), "missing \(name).mscx")
        return try ScoreBridge.loadScore(bytes: Data(contentsOf: url))
    }

    private static func options(_ mode: LayoutOptionsWire.Mode) -> LayoutOptionsWire {
        var options = LayoutOptionsWire.verticalDefault
        options.layoutMode = mode.rawValue
        return options
    }

    /// `score` in `.page` mode on an A4 page with `margins`.
    private static func pages(_ score: Score, margins: LayoutBridge.PageMargins) -> LayoutPages {
        LayoutBridge.computePages(
            score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: options(.page),
            margins: margins,
        )
    }

    /// The edge-to-edge page model as it stood before margins existed, frozen here: cut at the full page height,
    /// each page lifted by the bottom of the previous page's last system, the title block on the first page only,
    /// every page exactly A4 with the music from its top-left corner.
    private static func edgeToEdgePages(_ document: LayoutDocument) -> (pages: [EncodablePage], spans: [[SystemSpan]]) {
        let ranges = LayoutPaginator.paginate(
            systems: document.systems, pageHeight: CGFloat(pageHeightMM * mmToPt), policy: options(.page).breakPolicy,
        )
        var pages: [EncodablePage] = []
        var spans: [[SystemSpan]] = []
        for range in ranges {
            let pageTop: CGFloat = range.lowerBound == 0
                ? 0
                : document.systems[range.lowerBound - 1].origin.y + document.systems[range.lowerBound - 1].size.height
            let sub = document.subdocument(systems: range, yOffset: -pageTop)
            let pageDocument = range.lowerBound == 0
                ? LayoutDocument(
                    size: sub.size, systems: sub.systems, metrics: sub.metrics, titleFrame: document.titleFrame,
                )
                : sub
            let built = LayoutBridge.buildCommandsWithSpans(layout: pageDocument)
            pages.append(EncodablePage(widthMM: pageWidthMM, heightMM: pageHeightMM, commands: built.commands))
            spans.append(built.spans.map { span in
                var span = span
                span.systemIndex = span.systemIndex.map { $0 + range.lowerBound }
                return span
            })
        }
        return (pages, spans)
    }

    /// Apple's sheet width, restated (`MacPageDeckMetrics.pageSize(forDocumentWidth:)` in folino): the page width, or
    /// the widest system's right edge plus both side margins when that edge passes the printable width.
    private static func paperWidthMM(_ document: LayoutDocument, _ margins: LayoutBridge.PageMargins) -> Double {
        let musicRightPt = document.systems.map { Double($0.origin.x + $0.size.width) }.max() ?? 0
        let printableWidthPt = Double(CGFloat((pageWidthMM - margins.leading - margins.trailing) * mmToPt))
        guard musicRightPt > printableWidthPt else { return pageWidthMM }
        return max(pageWidthMM, musicRightPt * ptToMM + margins.leading + margins.trailing)
    }

    /// One part of `measures` 4/4 measures of quarters. With `wideMeasure`, measure 2 is a 96/4 measure of 96
    /// quarters — 153.6 sp at the 1.6 sp a quarter is given at least, far wider than an A4 line — which the engine
    /// gives a system of its own that overflows the printable width.
    private static func musicXML(measures: Int, wideMeasure: Bool) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
        <part-list><score-part id="P1"><part-name>Part</part-name></score-part></part-list>
        <part id="P1">

        """
        let steps = ["C", "D", "E", "F"]
        for measure in 1 ... measures {
            let isWide = wideMeasure && measure == 2
            xml += "<measure number=\"\(measure)\">"
            if measure == 1 {
                xml += "<attributes><divisions>1</divisions><key><fifths>0</fifths></key>"
                xml += "<time><beats>4</beats><beat-type>4</beat-type></time>"
                xml += "<clef><sign>G</sign><line>2</line></clef></attributes>"
            } else if isWide {
                xml += "<attributes><time><beats>96</beats><beat-type>4</beat-type></time></attributes>"
            } else if wideMeasure, measure == 3 {
                xml += "<attributes><time><beats>4</beats><beat-type>4</beat-type></time></attributes>"
            }
            for note in 0 ..< (isWide ? 96 : 4) {
                xml += "<note><pitch><step>\(steps[note % 4])</step><octave>5</octave></pitch>"
                xml += "<duration>1</duration><type>quarter</type></note>"
            }
            xml += "</measure>\n"
        }
        return xml + "</part>\n</score-partwise>\n"
    }
}
