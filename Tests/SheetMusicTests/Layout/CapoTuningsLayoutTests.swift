#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Capo and string-tunings texts: staff-text style (tunings at 9 pt), above by default, the tunings one spatium in
/// from the measure's left edge.
@Suite("Capo and string tunings layout")
struct CapoTuningsLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    @Test("a capo draws its text above the staff at its beat, like a staff text")
    func capoDrawsItsText() throws {
        let capoDocument = F.layout(F.score([.capo(Capo(fretPosition: 3, text: "Capo 3")), F.whole()]))
        let textDocument = F.layout(F.score(
            [F.whole()],
            system: [PositionedSystemElement(
                position: .start, element: .staffText(StaffText(text: "Capo 3")), originalStaff: F.address,
            )],
        ))
        let capo = try #require(F.staffTexts(capoDocument).first)
        let text = try #require(F.staffTexts(textDocument).first)
        #expect(capo.style == .staffText)
        #expect(capo.placement?.side == .above)
        #expect(abs(capo.origin.x - text.origin.x) < 0.001)
        #expect(abs(capo.origin.y - text.origin.y) < 0.001)
    }

    @Test("an empty capo text falls back to the generated one; an empty tunings text draws nothing")
    func emptyTexts() {
        let capo = F.layout(F.score([.capo(Capo(fretPosition: 2, text: "")), F.whole()]))
        #expect(F.staffTexts(capo).map(\.text) == ["Capo 2"])
        let tunings = F.layout(F.score([.stringTunings(StringTunings(text: "")), F.whole()]))
        #expect(F.staffTexts(tunings).isEmpty)
    }

    @Test("string tunings sit one spatium from the measure's left edge, in their own 9 pt style")
    func tuningsAnchorAtMeasureStart() throws {
        let document = F.layout(F.score([
            F.whole(), .stringTunings(StringTunings(text: "Drop D")),
        ]))
        let tunings = try #require(F.staffTexts(document).first)
        #expect(tunings.style == .stringTunings)
        #expect(abs(tunings.origin.x - F.sp) < 0.01)
        let size = TextInkGeometry.font(for: .stringTunings, metrics: F.metrics).pointSize
        #expect(abs(size - 9 * F.sp / 5) < 0.001)
    }

    @Test("a hidden capo draws nothing, and is a ghost when invisible elements are shown")
    func hiddenCapo() {
        var hidden = Capo(fretPosition: 2, text: "Capo 2")
        hidden.visible = false
        let score = F.score([.capo(hidden), F.whole()])
        #expect(F.staffTexts(F.layout(score)).isEmpty)
        let ghosts = F.layout(score, showsInvisible: true).systems.flatMap(\.measures).flatMap(\.invisibleElements)
        #expect(ghosts.count { if case .staffText = $0 { true } else { false } } == 1)
    }
}
