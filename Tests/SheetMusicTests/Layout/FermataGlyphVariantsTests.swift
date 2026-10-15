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

/// F6.1: MuseScore's fourteen fermata symbols (`dom/fermata.cpp:269-284`) each draw their own SMuFL glyph. The side is
/// the placement's — `<placement>`, else below for the second and fourth voice — and the glyph is the subtype's form
/// for that side (`TLayout::layoutFermata`, `tlayout.cpp:1919-1929`).
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

    /// MuseScore 4.7.4 draws the fixture's first-voice `fermataLongBelow` (no `<placement>`) upright over the staff,
    /// exactly like the `fermataLongAbove` beside it: the placement, not the subtype, decides the side.
    @Test("a first-voice fermataLongBelow with no placement draws the long fermata upright above the staff")
    func longBelowFollowsItsPlacement() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fermata-breath-variants"))
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 2400)
        let fermatas = document.systems.flatMap { $0.measures.flatMap(\.elements) }
            .compactMap { element -> (String, CGPoint)? in
                if case let .fermata(subtype, origin, _) = element { return (subtype, origin) }
                return nil
            }
        // The fixture's first two fermatas are `fermataLongAbove` then `fermataLongBelow`, both first voice.
        try #require(fermatas.count >= 2)
        #expect(fermatas[0].0 == "fermataLongAbove")
        #expect(fermatas[1].0 == "fermataLongAbove")
        #expect(abs(fermatas[0].1.y - fermatas[1].1.y) < 0.001)
        #expect(!fermatas.contains { $0.0.hasSuffix("Below") })
    }

    @Test("the side is the placement's, else the voice's; the drawn form follows the side")
    func placementDecidesTheSide() {
        #expect(FermataGlyph.placedBelow(placement: nil, voiceIndex: 0) == false)
        #expect(FermataGlyph.placedBelow(placement: nil, voiceIndex: 1) == true)
        #expect(FermataGlyph.placedBelow(placement: nil, voiceIndex: 3) == true)
        #expect(FermataGlyph.placedBelow(placement: .below, voiceIndex: 0) == true)
        #expect(FermataGlyph.placedBelow(placement: .above, voiceIndex: 1) == false)
        #expect(FermataGlyph.drawnSubtype("fermataLongBelow", below: false) == "fermataLongAbove")
        #expect(FermataGlyph.drawnSubtype("fermataShortHenzeAbove", below: true) == "fermataShortHenzeBelow")
        #expect(FermataGlyph.drawnSubtype("fermataAbove", below: false) == "fermataAbove")
        #expect(FermataGlyph.drawnSubtype("curlewSign", below: true) == "curlewSign")
    }

    @Test("a fermata placed below hangs under the staff with the below glyph")
    func placedBelowHangsUnder() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fermata-breath-variants"))
        let address = try #require(Self.firstFermata(in: score))
        guard case var .fermata(fermata) = score[address] else {
            Issue.record("expected a fermata")
            return
        }
        fermata.elementProperties.placement = .below
        score[address] = .fermata(fermata)
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 2400)
        let fermatas = document.systems.flatMap { $0.measures.flatMap(\.elements) }
            .compactMap { element -> (String, CGPoint)? in
                if case let .fermata(subtype, origin, _) = element { return (subtype, origin) }
                return nil
            }
        try #require(fermatas.count >= 2)
        #expect(fermatas[0].0 == "fermataLongBelow")
        #expect(FermataGlyph.codepoint(forSubtype: fermatas[0].0) == 0xE4C7)
        #expect(fermatas[0].1.y > fermatas[1].1.y)
    }

    private static func firstFermata(in score: Score) -> VoiceElementID? {
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard let index = voice.elements.firstIndex(where: { if case .fermata = $0 { true } else { false } }) else {
            return nil
        }
        return VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0,
            elementIndex: index,
        )
    }
}
