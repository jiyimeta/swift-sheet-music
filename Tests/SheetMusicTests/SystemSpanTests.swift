import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import Testing

/// `LayoutBridge.computePages` and the `SystemSpan`s it records: the contract a renderer that draws a page in pieces
/// (the Windows onscreen surface) relies on — spans that tile the page's commands, a frame that holds everything a span
/// paints, and no state carried from one span into the next.
@Suite("SystemSpan")
struct SystemSpanTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Real scores with several systems, spanners, repeats and multiple staves.
    private static let fixtures = [
        "midi01", "midi02", "midi03", "testArpeggio", "testVoltaDynamic", "testRepeatsWithKeySigs",
        "multiPartMixedStaves", "slur_ms4_resave", "spanner_offsets_score_end",
    ]

    private static let pageWidthMM = 210.0
    private static let pageHeightMM = 297.0

    private static func load(_ name: String) throws -> Score {
        let url = try #require(TestResources.url(forResource: name, withExtension: "mscx"), "missing \(name).mscx")
        return try ScoreBridge.loadScore(bytes: Data(contentsOf: url))
    }

    private static func options(_ mode: LayoutOptionsWire.Mode) -> LayoutOptionsWire {
        var options = LayoutOptionsWire.verticalDefault
        options.layoutMode = mode.rawValue
        return options
    }

    private static var modes: [LayoutOptionsWire.Mode] {
        [.vertical, .horizontal, .page]
    }

    private static func pages(_ name: String, _ mode: LayoutOptionsWire.Mode) throws -> LayoutPages {
        try LayoutBridge.computePages(
            score: load(name), pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: options(mode),
        )
    }

    @Test("the spans tile each page's commands, one per system and at most one for the title", arguments: fixtures)
    func spansTileEveryPage(fixture: String) throws {
        for mode in Self.modes {
            let result = try Self.pages(fixture, mode)
            #expect(result.spans.count == result.pages.count, "\(fixture) \(mode)")
            var systemsSeen: [Int] = []
            for (page, spans) in zip(result.pages, result.spans) {
                var next = 0
                for span in spans {
                    #expect(span.commandRange.lowerBound == next, "\(fixture) \(mode): gap or overlap at \(next)")
                    next = span.commandRange.upperBound
                    if let index = span.systemIndex { systemsSeen.append(index) }
                }
                #expect(next == page.commands.count, "\(fixture) \(mode): commands after the last span")
                #expect(spans.count(where: { $0.systemIndex == nil }) <= 1, "\(fixture) \(mode): two title spans")
            }
            // Every system of the document exactly once, in order, across all pages.
            #expect(systemsSeen == Array(result.document.systems.indices), "\(fixture) \(mode)")
        }
    }

    @Test("a span's frame holds every point it paints", arguments: fixtures)
    func framesHoldTheirCommands(fixture: String) throws {
        for mode in Self.modes {
            let result = try Self.pages(fixture, mode)
            for (page, spans) in zip(result.pages, result.spans) {
                for span in spans {
                    for command in page.commands[span.commandRange] {
                        for point in Self.anchorPoints(of: command) {
                            #expect(
                                Self.contains(span.frameMM, point),
                                "\(fixture) \(mode): \(command) outside \(span.frameMM)",
                            )
                        }
                    }
                }
            }
        }
    }

    @Test(
        "walking a span alone from the default state gives the full walk's state at every command",
        arguments: fixtures,
    )
    func noStateCrossesASpan(fixture: String) throws {
        for mode in Self.modes {
            let result = try Self.pages(fixture, mode)
            for (page, spans) in zip(result.pages, result.spans) {
                let whole = WalkState.states(page.commands[...])
                for span in spans {
                    let alone = WalkState.states(page.commands[span.commandRange])
                    #expect(
                        alone == Array(whole[span.commandRange]),
                        "\(fixture) \(mode): state leaks into span \(String(describing: span.systemIndex))",
                    )
                }
            }
        }
    }

    @Test("the pages are computeWithDocument's, byte for byte", arguments: fixtures)
    func pagesMatchComputeWithDocument(fixture: String) throws {
        for mode in Self.modes {
            let score = try Self.load(fixture)
            let viaPages = LayoutBridge.computePages(
                score: score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                options: Self.options(mode),
            )
            let viaBytes = LayoutBridge.computeWithDocument(
                score: score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                options: Self.options(mode),
            )
            #expect(DrawProgramCodec.encode(pages: viaPages.pages) == viaBytes.encoded, "\(fixture) \(mode)")
            #expect(viaPages.document.systems.count == viaBytes.document.systems.count, "\(fixture) \(mode)")
        }
    }

    @Test("a titled score has a title span on its first page only")
    func titleSpan() throws {
        let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [measure])])],
            systemMeasures: [SystemMeasure()],
            titleFrame: ScoreFrame(heightSp: 12, texts: [FrameText(style: .title, text: "My Title")]),
        )
        for mode in [LayoutOptionsWire.Mode.vertical, .page] {
            let result = LayoutBridge.computePages(
                score: score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                options: Self.options(mode),
            )
            let title = try #require(result.spans.first?.first, "\(mode)")
            #expect(title.systemIndex == nil, "\(mode)")
            #expect(!title.commandRange.isEmpty, "\(mode)")
            #expect(result.spans.dropFirst().allSatisfy { $0.allSatisfy { $0.systemIndex != nil } }, "\(mode)")
        }
    }

    @Test("DrawRect union and intersection")
    func drawRect() {
        let a = DrawRect(x: 0, y: 0, width: 10, height: 10)
        let b = DrawRect(x: 5, y: 8, width: 10, height: 10)
        #expect(a.union(b) == DrawRect(x: 0, y: 0, width: 15, height: 18))
        #expect(a.intersects(b))
        #expect(!a.intersects(DrawRect(x: 10, y: 0, width: 5, height: 5))) // touching edges
    }

    // MARK: - Helpers

    /// The points a command certainly paints at — its own coordinates, not a guess at its ink.
    private static func anchorPoints(of command: DrawCommand) -> [(x: Double, y: Double)] {
        switch command {
        case let .moveTo(x, y), let .lineTo(x, y): [(x, y)]
        case let .cubicTo(_, _, _, _, x, y): [(x, y)]
        case let .fillRect(x, y, w, h): [(x, y), (x + w, y + h)]
        case let .glyph(_, x, y, _, _): [(x, y)]
        case let .text(_, x, y, _, _), let .italicText(_, x, y, _, _): [(x, y)]
        case let .stretchedGlyph(_, rightEdgeX, topY, bottomY, _, _, _): [(rightEdgeX, topY), (rightEdgeX, bottomY)]
        case .stroke, .setColor, .setRotation, .setDash, .setTextStyle: []
        }
    }

    private static func contains(_ rect: DrawRect, _ point: (x: Double, y: Double)) -> Bool {
        let epsilon = 1e-6
        return point.x >= rect.x - epsilon && point.x <= rect.maxX + epsilon
            && point.y >= rect.y - epsilon && point.y <= rect.maxY + epsilon
    }
}

/// The draw program's state as a walker sees it before each command.
private struct WalkState: Equatable {
    var argb: UInt32 = 0xFF00_0000
    var dashOn = 0.0
    var dashOff = 0.0
    var rotation = 0.0
    var pivotX = 0.0
    var pivotY = 0.0
    var textStyle: UInt8 = 0
    /// A path begun with moveTo and not yet stroked: a span must not start inside one.
    var pathOpen = false

    static func states(_ commands: ArraySlice<DrawCommand>) -> [WalkState] {
        var state = WalkState()
        var out: [WalkState] = []
        out.reserveCapacity(commands.count)
        for command in commands {
            out.append(state)
            switch command {
            case let .setColor(argb): state.argb = argb
            case let .setDash(on, off): (state.dashOn, state.dashOff) = (on, off)
            case let .setRotation(radians, pivotX, pivotY):
                (state.rotation, state.pivotX, state.pivotY) = (radians, pivotX, pivotY)
            case let .setTextStyle(flags): state.textStyle = flags
            case .moveTo: state.pathOpen = true
            case .stroke: state.pathOpen = false
            default: break
            }
        }
        return out
    }
}
