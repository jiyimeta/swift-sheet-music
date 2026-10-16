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
#endif

/// A chord symbol is room its beat must keep, not weight its beat carries: MuseScore spaces a bar by its durations and
/// lets a symbol widen a beat only where it would otherwise run into the next one.
@Suite("Chord symbol spacing")
struct HarmonySpacingTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func layout(_ source: String, wrap: Bool) throws -> LayoutDocument {
        let score = try MSCXParser.parse(Data(source.utf8))
        let options = ScoreViewOptions(staffSize: 28, wrapToViewWidth: wrap)
        let width = wrap ? 900 : LayoutEngine.naturalContentWidth(score: score, options: options)
        return LayoutEngine.layout(score: score, options: options, availableWidth: width)
    }

    private static func fixture() throws -> String {
        try #require(String(bytes: MSCXFixtureLoader.mscxData("chord-symbol-case"), encoding: .utf8))
    }

    /// The x of every chord, left to right.
    private static func chordXs(_ document: LayoutDocument) -> [CGFloat] {
        document.systems.flatMap(\.measures).flatMap { measure in
            measure.elements.compactMap { element -> CGFloat? in
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
                return notes.first.map { measure.origin.x + $0.origin.x }
            }
        }.sorted()
    }

    /// MuseScore 4.7 draws `own/chord-symbol-case` — four quarters under cm7, Cmaj7, cdim and C7/D, stretched across
    /// the line — with its four beats evenly spaced.
    @Test("chord symbols leave a stretched bar of equal notes evenly spaced")
    func stretchedBarStaysEven() throws {
        let xs = try Self.chordXs(Self.layout(Self.fixture(), wrap: true))
        try #require(xs.count == 4)
        let gaps = zip(xs.dropFirst(), xs).map { $0 - $1 }
        let spread = (gaps.max() ?? 0) - (gaps.min() ?? 0)
        #expect(spread < 0.5, "beat gaps \(gaps)")
    }

    /// Eighths in 2/4 under long symbols: each symbol is wider than its beat's natural room, so the bar must give way.
    @Test(
        "a symbol wider than its beat still keeps clear of the next one, stretched or not",
        arguments: [true, false],
    )
    func wideSymbolsStayApart(wrap: Bool) throws {
        var source = try Self.fixture()
        for name in ["m7", "maj7", "dim", "7"] {
            source = source.replacingOccurrences(
                of: "<name>\(name)</name>", with: "<name>\(name)(b9,#11,13)</name>",
            )
        }
        source = source.replacingOccurrences(of: "<sigN>4</sigN>", with: "<sigN>2</sigN>")
            .replacingOccurrences(
                of: "<durationType>quarter</durationType>", with: "<durationType>eighth</durationType>",
            )
        let document = try Self.layout(source, wrap: wrap)
        let harmonies = document.systems.flatMap(\.measures).flatMap { measure in
            measure.elements.compactMap { element -> LayoutHarmony? in
                if case let .harmony(harmony) = element { harmony } else { nil }
            }
        }.sorted { $0.anchorX < $1.anchorX }
        try #require(harmonies.count == 4)
        for (left, right) in zip(harmonies, harmonies.dropFirst()) {
            #expect(
                left.anchorX + left.width <= right.anchorX + 0.001, "\(left.anchorX)+\(left.width) > \(right.anchorX)",
            )
        }
    }
}
