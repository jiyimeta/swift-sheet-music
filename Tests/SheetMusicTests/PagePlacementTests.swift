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

/// `LayoutBridge.PagePlacement`: where `encodePagesWithSpans` draws a document's points, and back — what a host needs
/// to put its own marks (ink, a playback cursor) on a page in `.page` mode, where a page shows the document lifted and
/// moved in by the margins.
///
/// The oracle is the drawing itself. The same document encoded in `.vertical` mode is one page in the document's own
/// coordinates (no lift, no margins); every page-mode system's first positioned command must be that vertical command
/// carried through the placement.
@Suite("Page placement")
struct PagePlacementTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// `PageMarginsTests`' scores: several systems and pages, spanners, repeats and multiple staves.
    private static let fixtures = [
        "midi01", "midi02", "midi03", "testArpeggio", "testVoltaDynamic", "testRepeatsWithKeySigs",
        "multiPartMixedStaves", "slur_ms4_resave", "spanner_offsets_score_end",
    ]

    private static let pageWidthMM = 210.0
    private static let pageHeightMM = 297.0
    private static let tenMM = LayoutBridge.PageMargins(top: 10, leading: 12, bottom: 10, trailing: 8)
    private static let mmToPt = 72.0 / 25.4
    private static let epsilon = 1e-6

    @Test("a page draws each system where the placement maps its document points", arguments: fixtures)
    func placementMatchesTheCommands(fixture: String) throws {
        let score = try Self.load(fixture)
        var compared = 0
        for margins in [LayoutBridge.PageMargins.zero, Self.tenMM] {
            let paged = Self.pages(score, margins: margins, mode: .page)
            let placement = LayoutBridge.pagePlacement(
                document: paged.document, options: Self.options(.page), pageHeightMM: Self.pageHeightMM,
                margins: margins,
            )
            #expect(placement.pageCount == paged.pages.count, "\(fixture)")
            let flat = LayoutBridge.encodePagesWithSpans(
                document: paged.document, options: Self.options(.vertical), pageWidthMM: Self.pageWidthMM,
                pageHeightMM: Self.pageHeightMM,
            )
            for (pageIndex, spans) in paged.spans.enumerated() {
                for span in spans {
                    guard let system = span.systemIndex,
                          let flatSpan = flat.spans[0].first(where: { $0.systemIndex == system }),
                          let onPage = Self.firstPosition(paged.pages[pageIndex].commands[span.commandRange]),
                          let inDocument = Self.firstPosition(flat.pages[0].commands[flatSpan.commandRange])
                    else { continue }
                    let label = "\(fixture) page \(pageIndex + 1) system \(system)"
                    let mapped = placement.pageMM(
                        fromDocumentX: inDocument.x * Self.mmToPt, y: inDocument.y * Self.mmToPt, page: pageIndex,
                    )
                    #expect(abs(mapped.x - onPage.x) < Self.epsilon, "\(label): x \(mapped.x) vs \(onPage.x)")
                    #expect(abs(mapped.y - onPage.y) < Self.epsilon, "\(label): y \(mapped.y) vs \(onPage.y)")
                    let back = placement.documentPoint(fromPage: pageIndex, xMM: onPage.x, yMM: onPage.y)
                    #expect(abs(back.x - inDocument.x * Self.mmToPt) < Self.epsilon, "\(label)")
                    #expect(abs(back.y - inDocument.y * Self.mmToPt) < Self.epsilon, "\(label)")
                    let box = paged.document.systems[system]
                    let middle = Double(box.origin.y + box.size.height / 2)
                    #expect(placement.page(containingDocumentY: middle) == pageIndex, "\(label)")
                    compared += 1
                }
            }
        }
        #expect(compared > 0, "\(fixture): no system was compared")
    }

    @Test("vertical and horizontal draw one unlifted page and ignore the margins")
    func singlePageModes() throws {
        let score = try Self.load("midi01")
        for mode in [LayoutOptionsWire.Mode.vertical, .horizontal] {
            let laidOut = Self.pages(score, margins: .zero, mode: mode)
            let placement = LayoutBridge.pagePlacement(
                document: laidOut.document, options: Self.options(mode), pageHeightMM: Self.pageHeightMM,
                margins: Self.tenMM,
            )
            #expect(placement.pageTopsPt == [0], "\(mode)")
            let mapped = placement.pageMM(fromDocumentX: 72, y: 144, page: 0)
            #expect(abs(mapped.x - 25.4) < 1e-9, "\(mode)")
            #expect(abs(mapped.y - 50.8) < 1e-9, "\(mode)")
            #expect(placement.page(containingDocumentY: 1e6) == 0, "\(mode)")
        }
    }

    @Test("a point above every page's top is on the first page; a layout with no pages has no page")
    func edges() {
        let placement = LayoutBridge.PagePlacement(pageTopsPt: [0, 700, 1400], contentOffsetXMM: 0, contentOffsetYMM: 0)
        #expect(placement.page(containingDocumentY: -5) == 0)
        #expect(placement.page(containingDocumentY: 700) == 1)
        #expect(placement.page(containingDocumentY: 1399.9) == 1)
        #expect(placement.page(containingDocumentY: 9000) == 2)
        let empty = LayoutBridge.PagePlacement(pageTopsPt: [], contentOffsetXMM: 0, contentOffsetYMM: 0)
        #expect(empty.page(containingDocumentY: 0) == nil)
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

    private static func pages(
        _ score: Score, margins: LayoutBridge.PageMargins, mode: LayoutOptionsWire.Mode,
    ) -> LayoutPages {
        LayoutBridge.computePages(
            score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: options(mode),
            margins: margins,
        )
    }

    /// The first point a run of commands puts down: a path's first point, a rectangle's origin, a glyph's or text's
    /// origin.
    private static func firstPosition(_ commands: ArraySlice<DrawCommand>) -> (x: Double, y: Double)? {
        for command in commands {
            switch command {
            case let .moveTo(x, y), let .lineTo(x, y): return (x, y)
            case let .fillRect(x, y, _, _): return (x, y)
            case let .glyph(_, x, y, _, _), let .text(_, x, y, _, _): return (x, y)
            default: continue
            }
        }
        return nil
    }
}
