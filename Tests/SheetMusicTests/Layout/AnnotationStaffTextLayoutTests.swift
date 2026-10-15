#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A play technique draws as the staff text it is; a harp pedal diagram in its own style, centered, above (glyph mode)
/// or below (text mode); neither is a caret target.
@Suite("Annotation staff text layout")
struct AnnotationStaffTextLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    private static func lane(_ text: StaffText) -> [PositionedSystemElement] {
        [PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: F.address)]
    }

    @Test("a play technique is positioned exactly like a staff text of the same words, but not addressable")
    func techniqueLooksLikeStaffText() throws {
        var pizz = StaffText(text: "pizz.")
        pizz.annotation = .playTechnique(.pizzicato, playsBack: true)
        let annotated = F.layout(F.score([F.whole()], system: Self.lane(pizz)))
        let plain = F.layout(F.score([F.whole()], system: Self.lane(StaffText(text: "pizz."))))
        let a = try #require(F.staffTexts(annotated).first)
        let b = try #require(F.staffTexts(plain).first)
        #expect(a.origin == b.origin)
        #expect(a.style == .staffText)
        let element = try #require(F.elements(annotated).first { if case .staffText = $0 { true } else { false } })
        guard case let .staffText(_, _, _, _, anchor, _, _, identity, _) = element else { return }
        #expect(anchor == nil)
        #expect(identity == nil)
        let ordinary = try #require(F.elements(plain).first { if case .staffText = $0 { true } else { false } })
        guard case let .staffText(_, _, _, _, ordinaryAnchor, _, _, _, _) = ordinary else { return }
        #expect(ordinaryAnchor != nil)
    }

    @Test("a harp diagram draws its glyphs, centered on its beat, above the staff; the text mode below")
    func harpDiagrams() throws {
        let document = try F.layout(F.load("w5-diagrams"))
        let texts = F.staffTexts(document).filter { $0.style == .harpPedalDiagram || $0.style == .harpPedalTextDiagram }
        #expect(texts.map(\.style) == [.harpPedalDiagram, .harpPedalTextDiagram])
        try #require(texts.count == 2)
        #expect(texts[0].placement?.side == .above)
        #expect(texts[1].placement?.side == .below)
        let rich = try #require(texts[0].richText)
        // 7 pedal glyphs and the divider, in Bravura.
        let runs = rich.lines.flatMap(\.runs)
        #expect(runs.count == 8)
        let symbolRuns = runs.filter { if case .symbol = $0.content { true } else { false } }
        #expect(symbolRuns.count == runs.count)
        // Centered: the block's center sits on the first chord's column (± half a notehead).
        let noteX = try #require(F.chordNoteX(document))
        let ink = try #require(rich.ink)
        #expect(abs((texts[0].origin.x + ink.width / 2) - noteX) < 0.6 * F.sp)
    }

    @Test("a diagram with no text draws nothing")
    func emptyDiagramDrawsNothing() {
        var bare = StaffText(text: "")
        bare.annotation = .harpPedal(HarpPedalDiagram())
        #expect(F.staffTexts(F.layout(F.score([F.whole()], system: Self.lane(bare)))).isEmpty)
    }
}
