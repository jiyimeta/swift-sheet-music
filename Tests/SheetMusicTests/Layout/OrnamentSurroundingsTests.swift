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

/// What a chord's ornaments keep clear of and what is laid out around them, and the properties they carry.
@Suite("Ornament surroundings")
struct OrnamentSurroundingsTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures
    private typealias P = OrnamentProbe

    // MARK: - Neighbors

    @Test("a beam turning the chord's stem moves it: it clears the beam it stands over")
    func beamFlip() throws {
        // D5 alone points down; beamed with three low notes it points up.
        let trill = ChordOrnament(kind: .trill)
        let alone = P.layout([P.chord(74, .eighth, [trill])])
        let beamed = P.layout([
            P.chord(62, .eighth), P.chord(62, .eighth), P.chord(62, .eighth), P.chord(74, .eighth, [trill]),
        ])
        #expect(try #require(P.chords(alone).first).stem == .down)
        let last = try #require(P.chords(beamed).last)
        #expect(last.stem == .up && last.isBeamed)
        let ink = try #require(P.ornaments(beamed).first).ink
        #expect(try P.approximately(
            #require(P.ornaments(alone).first).ink.maxY, P.staffLines(alone).top - P.distance,
        ))
        #expect(ink.maxY <= last.stemOrigin.y - P.distance + 0.01)
        let staffTop = try P.staffLines(beamed).top
        #expect(ink.maxY < staffTop - P.distance)
    }

    @Test("on a beamed stem it stands off the stem's beamed tip")
    func beamedStemTip() throws {
        var ornament = ChordOrnament(kind: .trill)
        ornament.elementProperties.autoplace = false
        let document = P.layout([
            P.chord(62, .eighth, [ornament]), P.chord(74, .eighth),
            P.chord(62, .eighth), P.chord(62, .eighth),
        ])
        let first = try #require(P.chords(document).first)
        #expect(first.isBeamed && first.stem == .up)
        let head = try #require(first.notes.first)
        #expect(first.stemOrigin.y < head.origin.y - F.metrics.defaultStemLength - P.sp, "the beam lengthens it")
        #expect(try P.approximately(
            #require(P.ornaments(document).first).ink.maxY,
            min(P.staffLines(document).top, first.stemOrigin.y) - P.distance,
        ))
    }

    @Test("a beamed chord's articulation that changes side takes the ornament's limit with it")
    func beamFlipWithArticulation() throws {
        let trill = ChordOrnament(kind: .trill)
        let staccato = [ChordArticulation(kind: .staccato, anchor: .above)]
        let document = P.layout([
            P.chord(62, .eighth), P.chord(62, .eighth), P.chord(62, .eighth),
            P.chord(74, .eighth, [trill], articulations: staccato),
        ])
        let dot = try #require(P.articulationInk(document).first)
        let last = try #require(P.chords(document).last)
        let head = try #require(last.notes.first)
        #expect(dot.midY > head.origin.y)
        #expect(try P.approximately(
            #require(P.ornaments(document).first).ink.maxY,
            min(P.staffLines(document).top, last.stemOrigin.y) - P.distance,
        ))
    }

    @Test("it clears a taller neighbor its ink overlaps")
    func clearsNeighbors() throws {
        // A long prall on a 32nd C5 reaches over the 32nd C6 beside it.
        let prall = ChordOrnament(kind: .linePrall)
        let document = P.layout([P.chord(72, .thirtySecond, [prall]), P.chord(84, .thirtySecond)])
        let drawn = try #require(P.ornaments(document).first)
        let neighbor = try #require(P.chords(document).last?.notes.first)
        try #require(drawn.ink.maxX > neighbor.origin.x - P.sp / 2, "the ornament reaches over its neighbor")
        #expect(drawn.ink.maxY <= neighbor.origin.y - P.sp / 2 - P.distance + 0.01)
        var fixed = prall
        fixed.elementProperties.autoplace = false
        let still = P.layout([P.chord(72, .thirtySecond, [fixed]), P.chord(84, .thirtySecond)])
        #expect(try P.approximately(
            #require(P.ornaments(still).first).ink.maxY, P.staffLines(still).top - P.distance,
        ))
    }

    @Test("a fermata on the chord and a tuplet's number go outside it")
    func fermataAndTupletGoOutside() throws {
        let trill = ChordOrnament(kind: .trill)
        let withFermata = P.layout([
            .fermata(Fermata(subtype: "fermataAbove")), P.chord(72, .half, [trill]),
        ])
        let fermata = try #require(F.elements(withFermata).compactMap { element -> CGRect? in
            guard case let .fermata(subtype, origin, _) = element else { return nil }
            return LayoutElementShape.smuflGlyphRect(
                codepoint: FermataGlyph.codepoint(forSubtype: subtype), center: origin, sp: P.sp,
            )
        }.first)
        let underFermata = try #require(P.ornaments(withFermata).first).ink
        #expect(fermata.maxY <= underFermata.minY - P.distance + 0.01)

        let third = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
        let voice = Voice(
            elements: [P.chord(64, third), P.chord(65, third, [trill]), P.chord(67, third)],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)],
        )
        let triplet = F.layout(Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano"),
            staves: [Staff(lineCount: 5, measures: [Measure(voices: [voice])])],
        )]))
        let label = try #require(F.elements(triplet).compactMap { element -> CGFloat? in
            guard case let .tupletLabel(from, to, _, _, isAbove, _) = element, isAbove else { return nil }
            return (from.y + to.y) / 2
        }.first)
        let underNumber = try #require(P.ornaments(triplet).first).ink
        #expect(label + 0.75 * P.sp <= underNumber.minY - P.distance + 0.01)
    }

    // MARK: - Properties

    @Test("a hidden one is a ghost, on request, and takes no room; its color is the figure's")
    func hiddenAndColored() throws {
        var hidden = ChordOrnament(kind: .turn)
        hidden.elementProperties.visible = false
        var red = ChordOrnament(kind: .trill)
        red.elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0, alpha: 255)
        let elements = [P.chord(72, .whole, [hidden, red])]
        let document = P.layout(elements)
        let drawn = P.ornaments(document)
        #expect(drawn.map(\.codepoints) == [[0xE566]])
        #expect(drawn.first?.color == red.elementProperties.color)
        #expect(try P.approximately(
            #require(drawn.first).ink.maxY, P.staffLines(document).top - P.distance,
        ))
        let shown = P.layout(elements, showsInvisible: true)
        let ghosts = shown.systems.flatMap(\.measures)
        #expect(try P.approximately(
            #require(P.ornaments(shown).first).ink.maxY, P.staffLines(shown).top - P.distance,
        ))
        #expect(P.ornaments(ghosts.flatMap(\.invisibleElements)).map(\.codepoints) == [[0xE567]])
        #expect(P.ornaments(ghosts.flatMap(\.elements)).map(\.codepoints) == [[0xE566]])
    }

    @Test("a hidden chord's ornament is drawn, as its articulation is, above where the chord stands")
    func hiddenChord() throws {
        var chord = Chord(
            duration: .half, notes: ChordNotes([Note(pitch: 79, tpc: 15)]), ornaments: [ChordOrnament(kind: .trill)],
        )
        let shown = try #require(P.ornaments(P.layout([.chord(chord)])).first)
        chord.visible = false
        let hidden = try #require(P.ornaments(P.layout([.chord(chord)])).first)
        #expect(P.approximately(shown.ink.maxY, hidden.ink.maxY))
    }

    @Test("a chord drawn on the other staff takes its ornament along, as high over it as a chord written there")
    func staffMove() throws {
        let trill = "<Ornament><subtype>ornamentTrill</subtype></Ornament>"
        func rise(_ treble: String, _ bass: String) throws -> CGFloat {
            let score = try CrossStaffFixture.parse(CrossStaffFixture.piano(treble: [treble], bass: [bass]))
            let document = F.layout(score)
            let drawn = try #require(P.ornaments(document).first)
            let note = try #require(P.chords(document).first { !$0.notes.isEmpty }?.notes.first)
            return note.origin.y - drawn.ink.maxY
        }
        let whole = CrossStaffFixture.rest("measure")
        let written = try rise(whole, CrossStaffFixture.chord([(43, 15)], "whole", extra: trill))
        let moved = try rise(CrossStaffFixture.chord([(43, 15)], "whole", move: 1, extra: trill), whole)
        #expect(P.approximately(written, moved))
    }

    @Test("an offset away from the chord shows; one into it is lifted back out unless autoplace is off")
    func offsets() throws {
        /// How far the ornament's ink stands above the staff.
        func height(_ y: Double, autoplace: Bool? = nil) throws -> CGFloat {
            var ornament = ChordOrnament(kind: .trill)
            ornament.elementProperties.offset = ScoreOffset(x: 1, y: y)
            ornament.elementProperties.autoplace = autoplace
            let document = P.layout([P.chord(72, .half, [ornament])])
            let ink = try #require(P.ornaments(document).first).ink
            #expect(try P.approximately(ink.midX, #require(F.chordNoteX(document)) + P.sp))
            return try P.staffLines(document).top - ink.maxY
        }
        #expect(try P.approximately(height(-2), P.distance + 2 * P.sp))
        #expect(try P.approximately(height(2), P.distance))
        #expect(try P.approximately(height(2, autoplace: false), P.distance - 2 * P.sp))
    }

    @Test("the skyline sees it as an articulation, so annotations keep clear of it, and the system makes room for it")
    func skylineAndBounds() throws {
        let element = LayoutElement.figure(kind: .ornament, figure: LayoutFigure(primitives: []))
        #expect(LayoutElementShape.kind(of: element) == .articulation)
        let drawn = try #require(P.ornaments(P.layout([P.chord(79, .half, [
            ChordOrnament(kind: .trill), ChordOrnament(kind: .turnUp), ChordOrnament(kind: .trill),
        ])])).last)
        let points = LayoutEngine.elementYPoints(
            .figure(kind: .ornament, figure: drawn.figure), sp: P.sp,
        )
        #expect(points.min() == drawn.ink.minY)
        let text = VoiceElement.harmony(Harmony(name: "", rootTpc: 14))
        /// How far the chord symbol stands above the staff.
        func harmonyY(_ ornaments: [ChordOrnament]) throws -> CGFloat {
            let document = P.layout([text, P.chord(72, .half, ornaments)])
            let y = try #require(F.elements(document).compactMap { element -> CGFloat? in
                guard case let .harmony(harmony) = element else { return nil }
                return CGFloat(harmony.y)
            }.first)
            return try P.staffLines(document).top - y
        }
        let free = try harmonyY([])
        let pushed = try harmonyY([ChordOrnament(kind: .trill), ChordOrnament(kind: .trill)])
        #expect(pushed > free + P.sp / 2)
    }

    @Test("it names no item: a tap on it lands where a tap on an unaddressed mark does")
    func notSelectable() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let document = P.layout([P.chord(72, .half, [ChordOrnament(kind: .trill)])])
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first)
        let ink = try #require(P.ornaments(document).first).ink
        let point = CGPoint(
            x: system.origin.x + measure.origin.x + ink.midX, y: system.origin.y + measure.origin.y + ink.midY,
        )
        #expect(ScoreHitTester(document: document).hitTest(at: point) == nil)
        let chord = try #require(P.chords(document).first?.notes.first)
        let rescued = document.editingHitTest(at: point, activeVoice: 0, nearMissTolerance: P.sp * 6)
        #expect(rescued == .note(chord.noteID))
        #expect(measure.elements.allSatisfy { element in
            guard case .figure(.ornament, _, _, _) = element else { return true }
            return element.elementID == nil
        })
    }
}
