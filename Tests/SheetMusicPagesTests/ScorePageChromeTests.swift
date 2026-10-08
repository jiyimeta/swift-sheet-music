import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicPages
import Testing

/// `ScorePageChrome`: MuseScore's header and footer on a portable page, by `PageChromeRenderer`'s rules — measured
/// under the portable hosts' metrics table, as `ScorePagesTests` lays out.
@Suite("ScorePageChrome")
struct ScorePageChromeTests {
    private static let margins = PageMarginsMM.uniform(12.7)
    private static let meta = ["copyright": "© Folino"]

    private static func provider() throws -> any FontMetricsProvider {
        let table = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Web/sheet-music-web/assets/sheet-music.smft")
        return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: table)))
    }

    private struct Placed: Equatable {
        let text: String
        let x: Double
        let y: Double
    }

    /// The texts of `pageIndex`'s chrome under MuseScore's defaults, with where each is drawn.
    private static func texts(
        pageIndex: Int, pageCount: Int, chrome: PageChrome = .museScoreDefaults,
    ) throws -> [Placed] {
        try FontMetrics.$scopedProvider.withValue(provider()) {
            ScorePageChrome.commands(
                chrome: chrome, metaTags: meta, pageIndex: pageIndex, pageCount: pageCount, pageWidthMM: 210,
                pageHeightMM: 297, margins: margins,
            ).compactMap { command in
                guard case let .text(text, x, y, _, _) = command else { return nil }
                return Placed(text: text, x: x, y: y)
            }
        }
    }

    private static func inkWidthMM(_ text: String) throws -> Double {
        try FontMetrics.$scopedProvider.withValue(provider()) {
            let font = FontMetrics.provider.renderingTextFont(LayoutFont(face: "Edwin", pointSize: 9))
            return Double(FontMetrics.provider.inkBounds(text: text, font: font).width) * 25.4 / 72
        }
    }

    @Test func `the first page shows the copyright centered in the footer and no page number`() throws {
        let placed = try Self.texts(pageIndex: 0, pageCount: 3)

        #expect(placed.map(\.text) == ["© Folino"])
        let copyright = try #require(placed.first)
        let center = try copyright.x + (Self.inkWidthMM("© Folino")) / 2
        #expect(abs(center - 105) < 0.001, "centered between the side margins: \(center)")
        #expect(copyright.y > 297 - Self.margins.bottom && copyright.y < 297, "in the bottom margin: \(copyright.y)")
    }

    @Test func `an even page numbers itself at the leading margin, an odd one at the trailing margin`() throws {
        let second = try Self.texts(pageIndex: 1, pageCount: 3)
        let third = try Self.texts(pageIndex: 2, pageCount: 3)

        // `$C` is the first page's only; `$p` every page but the first.
        #expect(second.map(\.text) == ["2"])
        #expect(third.map(\.text) == ["3"])
        let two = try #require(second.first)
        let three = try #require(third.first)
        #expect(two.x == Self.margins.leading)
        #expect(try abs(three.x + (Self.inkWidthMM("3")) - (210 - Self.margins.trailing)) < 0.001)
        #expect(two.y > 0 && two.y < Self.margins.top, "in the top margin: \(two.y)")
        #expect(two.y == three.y)
    }

    @Test func `a disabled block prints nothing`() throws {
        var chrome = PageChrome.museScoreDefaults
        chrome.header.enabled = false
        chrome.footer.enabled = false

        #expect(try Self.texts(pageIndex: 1, pageCount: 3, chrome: chrome).isEmpty)
        let none = try FontMetrics.$scopedProvider.withValue(Self.provider()) {
            ScorePageChrome.commands(
                chrome: chrome, metaTags: Self.meta, pageIndex: 1, pageCount: 3, pageWidthMM: 210, pageHeightMM: 297,
                margins: Self.margins,
            )
        }
        #expect(none.isEmpty, "no color is set for a page with no chrome")
    }

    @Test func `a bold italic block names its style around the text and resets it`() throws {
        var chrome = PageChrome.museScoreDefaults
        chrome.footer.fontStyle = [.bold, .italic]
        let commands = try FontMetrics.$scopedProvider.withValue(Self.provider()) {
            ScorePageChrome.commands(
                chrome: chrome, metaTags: Self.meta, pageIndex: 0, pageCount: 1, pageWidthMM: 210, pageHeightMM: 297,
                margins: Self.margins,
            )
        }
        let styles = commands.compactMap { command -> UInt8? in
            guard case let .setTextStyle(flags) = command else { return nil }
            return flags
        }

        #expect(styles == [DrawCommand.TextStyleFlag.bold | DrawCommand.TextStyleFlag.italic, 0])
        #expect(commands.first == .setColor(argb: 0xFF00_0000))
    }
}
