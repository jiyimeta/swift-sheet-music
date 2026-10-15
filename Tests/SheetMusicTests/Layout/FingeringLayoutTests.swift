#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Fingerings: side by MuseScore's `calculatePlacement`, stacked from the chord outward, centered on the notehead.
@Suite("Fingering layout")
struct FingeringLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    private static func texts(_ document: LayoutDocument, style: TextStyleType) -> [F.StaffTextProbe] {
        F.staffTexts(document).filter { $0.style == style }
    }

    @Test("pure rules: voices and stem decide, else the last staff of a multi-staff part")
    func sideRules() {
        typealias G = FingeringGeometry
        func side(_ explicit: Placement?, up: Bool, voices: Bool, index: Int, count: Int) -> Placement {
            G.side(explicit: explicit, chordUp: up, hasVoices: voices, staffIndexInPart: index, staffCountInPart: count)
        }
        #expect(side(nil, up: true, voices: false, index: 0, count: 1) == .above)
        #expect(side(nil, up: false, voices: true, index: 0, count: 1) == .below)
        #expect(side(nil, up: true, voices: true, index: 1, count: 2) == .above)
        #expect(side(nil, up: true, voices: false, index: 1, count: 2) == .below)
        #expect(side(nil, up: true, voices: false, index: 0, count: 2) == .above)
        #expect(side(.below, up: true, voices: false, index: 0, count: 1) == .below)
    }

    @Test("stacking: the first clears the limit by the minimum distance, the rest sit a quarter of their height beyond")
    func stacking() {
        // Heights 8: the first center 3.5 + 4 beyond the limit, each next 8 + 0.25 × 8 further.
        let above = FingeringGeometry.stackedCenters(heights: [8, 8, 8], side: .above, limit: 100, minDistance: 3.5)
        let expectedAbove: [CGFloat] = [92.5, 82.5, 72.5]
        #expect(above == expectedAbove)
        let below = FingeringGeometry.stackedCenters(heights: [8, 8], side: .below, limit: 10, minDistance: 3.5)
        let expectedBelow: [CGFloat] = [17.5, 27.5]
        #expect(below == expectedBelow)
    }

    @Test("a third on the upper staff: both fingerings above, the lower note's nearest the chord, centered on it")
    func defaultAbove() throws {
        let document = try F.layout(F.load("w5-fingering-staves"))
        let fingerings = Self.texts(document, style: .fingering).filter { ["1", "3"].contains($0.text) }
        #expect(fingerings.count == 2)
        let one = try #require(fingerings.first { $0.text == "1" })
        let three = try #require(fingerings.first { $0.text == "3" })
        #expect(one.placement?.side == .above && three.placement?.side == .above)
        #expect(one.origin.y > three.origin.y)
        // Above the chord's notes by at least the minimum distance.
        let noteY = try #require(F.chordNoteY(document, nth: 0))
        #expect(one.origin.y <= noteY - 0.5 * F.sp)
        #expect(one.placement?.autoplace == false)
        let noteX = try #require(F.chordNoteX(document, nth: 0))
        let width = one.richText?.size.width ?? TextInkGeometry.typographicSize(
            text: "1", font: TextInkGeometry.font(for: .fingering, metrics: F.metrics),
        ).width
        #expect(abs(one.origin.x + width / 2 - noteX) < 0.6)
    }

    /// Measured off MuseScore 4.7's engraving of this fixture at 600 dpi (41.25 px a space): the "1" sits on its
    /// baseline 0.53 sp over the top line — the E5's head top — and the "3" stacks 1.45 sp higher, baseline to
    /// baseline: a quarter of the digit's tight ink height beyond it, not of its line box.
    @Test("the stack is MuseScore's: the 3's baseline 1.45 sp over the 1's, the 1 half a space over its note")
    func stackCalibratedAgainstMuseScore() throws {
        let document = try F.layout(F.load("w5-fingering-staves"))
        let fingerings = Self.texts(document, style: .fingering)
        let one = try #require(fingerings.first { $0.text == "1" })
        let three = try #require(fingerings.first { $0.text == "3" })
        let font = TextInkGeometry.font(for: .fingering, metrics: F.metrics)
        let drop = LayoutEngine.textPlacementOrigin(text: "1", font: font, baseline: .zero, center: false).y
        let baselineOne = one.origin.y - drop
        let baselineThree = three.origin.y - drop
        #expect(abs((baselineOne - baselineThree) - 1.45 * F.sp) < 0.1 * F.sp)
        // The chord's top note, E5, a space above its first-listed C5: its head top half a space above its center.
        let noteTop = try #require(F.chordNoteY(document, nth: 0)) - 1.5 * F.sp
        #expect(abs((noteTop - baselineOne) - 0.53 * F.sp) < 0.1 * F.sp)
    }

    @Test("the lower staff of a grand staff puts its fingering below its chord")
    func grandStaffLowerStaffBelow() throws {
        let document = try F.layout(F.load("w5-fingering-staves"))
        let five = try #require(Self.texts(document, style: .fingering).first { $0.text == "5" })
        #expect(five.placement?.side == .below)
    }

    @Test("with two voices the stem decides: voice 1 above, voice 2 (stem down) below")
    func stemDownVoiceBelow() throws {
        let document = try F.layout(F.load("w5-fingering-staves"))
        let two = try #require(Self.texts(document, style: .fingering).first { $0.text == "2" })
        let four = try #require(Self.texts(document, style: .fingering).first { $0.text == "4" })
        #expect(two.placement?.side == .above)
        #expect(four.placement?.side == .below)
        #expect(four.origin.y > two.origin.y)
    }

    @Test("an explicit placement wins")
    func explicitPlacement() throws {
        var note = Note(pitch: 72, tpc: 14)
        var finger = Fingering(text: "2")
        finger.elementProperties.placement = .below
        note.fingerings = [finger]
        let document = F.layout(F.score([.chord(Chord(duration: .whole, notes: ChordNotes([note])))]))
        let fingering = try #require(Self.texts(document, style: .fingering).first)
        #expect(fingering.placement?.side == .below)
    }

    @Test("guitar: left-hand beside the note on its line, right-hand italic, string number circled")
    func guitarStyles() throws {
        let document = try F.layout(F.load("fingerings"))
        let lh = try #require(Self.texts(document, style: .lhGuitarFingering).first)
        #expect(lh.text == "2")
        let rh = try #require(Self.texts(document, style: .rhGuitarFingering).first)
        #expect(rh.text == "i")
        let number = try #require(Self.texts(document, style: .stringNumber).first)
        #expect(number.text == "3")
        let circles = F.elements(document).compactMap { element -> LayoutFigure? in
            if case let .figure(kind, figure, _, _) = element, kind == .stringNumber { figure } else { nil }
        }
        let circle = try #require(circles.first)
        guard case let .ellipse(rect, fill, width)? = circle.primitives.first else {
            Issue.record("the string number's frame is not an ellipse")
            return
        }
        #expect(!fill)
        #expect(abs(width - 0.1 * F.sp) < 0.001)
        #expect(rect.width >= rect.height)
        // The circle frames the digit's tight ink with MuseScore's 0.2 sp padding: the ink's middle is its middle.
        let font = TextInkGeometry.font(for: .stringNumber, metrics: F.metrics)
        let ink = try #require(FontMetrics.provider.textInkBounds(text: "3", font: font))
        let drop = LayoutEngine.textPlacementOrigin(text: "3", font: font, baseline: .zero, center: false).y
        let inkMidY = number.origin.y - drop - ink.midY
        #expect(abs(rect.midY - inkMidY) < 0.01)
        #expect(abs(rect.height - (ink.height + 0.4 * F.sp)) < 0.01 || rect.width > rect.height)
    }

    @Test("an offset moves a right-hand fingering, a hidden one is a ghost, an unknown style is not drawn")
    func offsetHiddenOther() throws {
        let document = try F.layout(F.load("fingerings"))
        var base = Note(pitch: 67, tpc: 15)
        var rh = Fingering(text: "i", role: .rightHandGuitar)
        base.fingerings = [rh]
        let plain = F.layout(F.score([.chord(Chord(duration: .whole, notes: ChordNotes([base])))]))
        rh.elementProperties.offset = ScoreOffset(x: 0, y: 1.5)
        base.fingerings = [rh]
        let moved = F.layout(F.score([.chord(Chord(duration: .whole, notes: ChordNotes([base])))]))
        let a = try #require(Self.texts(plain, style: .rhGuitarFingering).first)
        let b = try #require(Self.texts(moved, style: .rhGuitarFingering).first)
        #expect(abs((b.origin.y - a.origin.y) - 1.5 * F.sp) < 0.001)
        // `own/fingerings` carries a hidden `user_1` fingering "5": neither drawn nor, being unmodeled, a ghost.
        #expect(!F.staffTexts(document).contains { $0.text == "5" })
    }
}
