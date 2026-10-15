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
#endif

/// F6.1: MuseScore's fourteen fermata symbols (`dom/fermata.cpp:269-284`) each draw their own SMuFL glyph; a `*Below`
/// symbol is the below form and hangs under the staff.
@Suite("Fermata glyph variants")
struct FermataGlyphVariantsTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    static let table: [(name: String, codepoint: UInt32)] = [
        ("fermataAbove", 0xE4C0), ("fermataBelow", 0xE4C1),
        ("fermataVeryShortAbove", 0xE4C2), ("fermataVeryShortBelow", 0xE4C3),
        ("fermataShortAbove", 0xE4C4), ("fermataShortBelow", 0xE4C5),
        ("fermataLongAbove", 0xE4C6), ("fermataLongBelow", 0xE4C7),
        ("fermataVeryLongAbove", 0xE4C8), ("fermataVeryLongBelow", 0xE4C9),
        ("fermataLongHenzeAbove", 0xE4CA), ("fermataLongHenzeBelow", 0xE4CB),
        ("fermataShortHenzeAbove", 0xE4CC), ("fermataShortHenzeBelow", 0xE4CD),
    ]

    @Test("every MuseScore subtype maps to its own glyph")
    func everySubtypeHasItsGlyph() {
        let wrong = Self.table.filter { FermataGlyph.codepoint(forSubtype: $0.name) != $0.codepoint }
        #expect(wrong.map(\.name) == [])
    }

    @Test("a subtype hangs below exactly when its name ends in Below")
    func belowIsTheSuffix() {
        let below = Self.table.filter { FermataGlyph.isBelow($0.name) }.map(\.name)
        #expect(below == Self.table.map(\.name).filter { $0.hasSuffix("Below") })
        #expect(!FermataGlyph.isBelow("fermata"))
    }

    @Test("an unknown subtype keeps the plain above glyph")
    func unknownFallsBackToAbove() {
        #expect(FermataGlyph.codepoint(forSubtype: "") == 0xE4C0)
        #expect(FermataGlyph.codepoint(forSubtype: "ufermata") == 0xE4C0)
    }

    @Test("ink offsets are measured on the subtype's own glyph")
    func offsetsFollowTheGlyph() throws {
        let provider = FontMetrics.provider
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let baseline = (provider.ascent(font: font) - provider.descent(font: font)) / 2
        // The expected glyph comes from MuseScore's table, not from `FermataGlyph`: read off `FermataGlyph`, a wrong
        // glyph and offsets measured on that same wrong glyph would agree.
        for name in ["fermataShortBelow", "fermataVeryLongBelow", "fermataLongHenzeBelow"] {
            let expected = try #require(Self.table.first { $0.name == name }?.codepoint)
            let codepoint = try #require(UInt16(exactly: expected))
            let bbox = try #require(provider.glyphPathBoundingBox(font: font, codepoint: codepoint))
            let offsets = FermataGlyphMetrics.offsets(forSubtype: name)
            #expect(abs(offsets.topOffset - (baseline - bbox.maxY)) < 1e-9)
            #expect(abs(offsets.bottomOffset - (baseline - bbox.minY)) < 1e-9)
        }
    }

    @Test("a fermataLongBelow lays out below the staff and carries the long glyph")
    func longBelowLaysOutBelow() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fermata-breath-variants"))
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 2400)
        // Per system, so the two y values share a frame (the fixture puts the Long pair first).
        let perSystem = document.systems.map { system in
            system.measures.flatMap(\.elements).compactMap { element -> (String, CGPoint)? in
                if case let .fermata(subtype, origin, _) = element { return (subtype, origin) }
                return nil
            }
        }
        let system = try #require(perSystem.first { fermatas in
            fermatas.contains { $0.0 == "fermataLongBelow" } && fermatas.contains { $0.0 == "fermataLongAbove" }
        })
        let long = try #require(system.first { $0.0 == "fermataLongBelow" })
        let above = try #require(system.first { $0.0 == "fermataLongAbove" })
        #expect(long.1.y > above.1.y)
        #expect(FermataGlyph.codepoint(forSubtype: long.0) == 0xE4C7)
        #expect(FermataGlyph.isBelow(long.0))
        #expect(!FermataGlyph.isBelow(above.0))
    }
}
