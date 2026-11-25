#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// A drawn ornament names its chord and kind, which is the address `SetOrnament` takes: a click on its ink selects it,
/// and its removal command takes it off that chord.
@Suite("Ornament selection")
struct OrnamentSelectionTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures
    private typealias P = OrnamentProbe

    /// A chord's slot in `P.layout`'s one bar, which holds the chords alone.
    private static func slot(_ chord: Int = 0, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: voice,
            elementIndex: chord,
        )
    }

    /// The one bar's frame in document points.
    private static func base(_ document: LayoutDocument) throws -> CGPoint {
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first)
        return CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
    }

    private static func center(of ink: CGRect, in document: LayoutDocument) throws -> CGPoint {
        let base = try base(document)
        return CGPoint(x: base.x + ink.midX, y: base.y + ink.midY)
    }

    @Test(
        "each kind names its chord, a click on its ink selects it, and its removal takes it off",
        arguments: ChordOrnament.Kind.modeled,
    )
    func selectsAndRemoves(_ kind: ChordOrnament.Kind) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let elements = [P.chord(72, .half, [ChordOrnament(kind: kind)])]
        let anchor = Self.slot()
        let id = ScoreElementID.ornament(anchor: anchor, kind: kind)
        let document = P.layout(elements)
        let drawn = try #require(P.ornaments(document).first)
        #expect(drawn.anchor == anchor && drawn.kind == kind)
        #expect(F.elements(document).compactMap(\.elementID).contains(id))

        let tester = ScoreHitTester(document: document)
        let target = ScoreHitTarget.ornament(anchor: anchor, kind: kind)
        let point = try Self.center(of: drawn.ink, in: document)
        #expect(tester.hitTest(at: point) == target)
        #expect(tester.itemID(at: point) == .element(id))
        #expect(target.selectableItem == .element(id))
        let base = try Self.base(document)
        #expect(tester.elementHitRects(for: target) == [drawn.ink.offsetBy(dx: base.x, dy: base.y)])

        var score = F.score(elements)
        _ = try #require(id.removalCommand).apply(to: &score)
        guard case let .chord(chord)? = score[anchor] else { return #expect(Bool(false)) }
        #expect(chord.ornaments.isEmpty)
    }

    @Test("a click on its accidental, above or below, selects the ornament")
    func accidentalSelectsIt() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let ornament = ChordOrnament(kind: .turn, accidentalAbove: .sharp, accidentalBelow: .flat)
        let elements = [P.chord(72, .half, [ornament])]
        let document = P.layout(elements)
        let drawn = try #require(P.ornaments(document).first)
        let plain = try #require(LayoutEngine.ornamentFigure(ChordOrnament(kind: .turn), sp: P.sp, mag: 1))
        let target = ScoreHitTarget.ornament(anchor: Self.slot(), kind: .turn)
        let tester = ScoreHitTester(document: document)
        let base = try Self.base(document)
        // 0.3 sp inside the figure's top and bottom edges: in the accidentals, clear of the turn between them.
        let inset = 0.3 * P.sp
        #expect(drawn.ink.height > plain.ink.height + 2 * inset)
        for y in [drawn.ink.minY + inset, drawn.ink.maxY - inset] {
            #expect(tester.hitTest(at: CGPoint(x: base.x + drawn.ink.midX, y: base.y + y)) == target)
        }
    }

    @Test("two kinds on one chord are two items; two of one kind share theirs, and the command takes both")
    func kindsAndDuplicates() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let elements = [P.chord(72, .half, [
            ChordOrnament(kind: .trill), ChordOrnament(kind: .turn), ChordOrnament(kind: .trill),
        ])]
        let anchor = Self.slot()
        let document = P.layout(elements)
        let tester = ScoreHitTester(document: document)
        let drawn = P.ornaments(document)
        #expect(drawn.map(\.kind) == [.trill, .turn, .trill])
        for ornament in drawn {
            let point = try Self.center(of: ornament.ink, in: document)
            #expect(tester.hitTest(at: point) == .ornament(anchor: anchor, kind: ornament.kind))
        }
        let trill = ScoreElementID.ornament(anchor: anchor, kind: .trill)
        #expect(tester.elementHitRects(for: ScoreHitTarget(elementID: trill)).count == 2)
        var score = F.score(elements)
        _ = try #require(trill.removalCommand).apply(to: &score)
        guard case let .chord(chord)? = score[anchor] else { return #expect(Bool(false)) }
        #expect(chord.ornaments == [ChordOrnament(kind: .turn)])
    }

    @Test("an ornament in the second voice names that voice's chord")
    func secondVoice() {
        let trill = ChordOrnament(kind: .trill)
        let document = P.layout(voices: [[P.chord(72, .whole)], [P.chord(64, .half), P.chord(65, .half, [trill])]])
        let drawn = P.ornaments(document)
        #expect(drawn.map(\.anchor) == [Self.slot(1, voice: 1)])
    }

    @Test("on a beamed chord it keeps its chord and kind, whatever the beam does to its place")
    func beamed() throws {
        let trill = ChordOrnament(kind: .trill)
        let drawn = try #require(P.ornaments(P.layout([
            P.chord(62, .eighth), P.chord(62, .eighth), P.chord(62, .eighth), P.chord(74, .eighth, [trill]),
        ])).first)
        #expect(drawn.anchor == Self.slot(3) && drawn.kind == .trill)
    }

    @Test("on a chord drawn on the other staff it goes along, and names the chord where it is written")
    func movedChord() throws {
        let trill = "<Ornament><subtype>ornamentTrill</subtype></Ornament>"
        let score = try CrossStaffFixture.parse(CrossStaffFixture.piano(
            treble: [CrossStaffFixture.chord([(43, 15)], "whole", move: 1, extra: trill)],
            bass: [CrossStaffFixture.rest("measure")],
        ))
        let document = F.layout(score)
        let drawn = try #require(P.ornaments(document).first)
        let anchor = try #require(drawn.anchor)
        #expect(anchor.staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
        guard case let .chord(chord)? = score[anchor] else { return #expect(Bool(false)) }
        #expect(chord.ornaments == [ChordOrnament(kind: .trill)] && chord.staffMove == 1)
        // Beside its chord, which is on the lower staff.
        let note = try #require(P.chords(document).first { !$0.notes.isEmpty }?.notes.first)
        #expect(abs(note.origin.y - drawn.ink.midY) < 6 * P.sp)
    }

    @Test("a hidden one, shown greyed, still answers a click; unshown it is not there to click")
    func hidden() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var ornament = ChordOrnament(kind: .mordent)
        ornament.elementProperties.visible = false
        let elements = [P.chord(72, .half, [ornament])]
        let shown = P.layout(elements, showsInvisible: true)
        let ghost = try #require(P.ornaments(shown.systems.flatMap(\.measures).flatMap(\.invisibleElements)).first)
        let target = ScoreHitTarget.ornament(anchor: Self.slot(), kind: .mordent)
        let point = try Self.center(of: ghost.ink, in: shown)
        #expect(ScoreHitTester(document: shown).hitTest(at: point) == target)
        let hidden = P.layout(elements)
        #expect(ScoreHitTester(document: hidden).elementHitRects(for: target).isEmpty)
    }

    @Test("a touch host's near-miss hit reads it as it reads an articulation: not a note, so not the ornament")
    func editingHitTest() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let document = P.layout([P.chord(72, .half, [ChordOrnament(kind: .trill)])])
        let drawn = try #require(P.ornaments(document).first)
        let chord = try #require(P.chords(document).first?.notes.first)
        let rescued = try document.editingHitTest(
            at: Self.center(of: drawn.ink, in: document), activeVoice: 0, nearMissTolerance: P.sp * 6,
        )
        #expect(rescued == .note(chord.noteID))
    }

    @Test("a selection of it follows its chord's slot, keeping the kind")
    func mappingFollowsTheChord() {
        let id = ScoreItemID.element(.ornament(anchor: Self.slot(1), kind: .linePrall))
        let moved = id.mappingVoiceElements { location in
            VoiceElementID(
                staff: location.staff, measureIndex: location.measureIndex, voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex + 4,
            )
        }
        #expect(moved == .element(.ornament(anchor: Self.slot(5), kind: .linePrall)))
        #expect(id.mappingVoiceElements { _ in nil } == nil)
    }

    @Test("a figure built with no chord, and a figure of another kind, name nothing")
    func unaddressed() {
        let figure = LayoutElement.figure(
            kind: .ornament(anchor: nil, kind: .trill), figure: LayoutFigure(primitives: []),
        )
        #expect(figure.elementID == nil)
        #expect(LayoutElement.figure(kind: .symbol, figure: LayoutFigure(primitives: [])).elementID == nil)
    }
}
