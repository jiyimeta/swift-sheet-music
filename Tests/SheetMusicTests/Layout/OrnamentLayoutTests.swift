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

/// A chord's ornaments (`Chord.ornaments`): the glyphs of every modeled kind, MuseScore's side and its distances.
@Suite("Ornament layout")
struct OrnamentLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures
    private typealias P = OrnamentProbe

    // MARK: - Glyphs

    @Test(
        "every modeled kind is drawn, the seven with no codepoint of their own from their pieces",
        arguments: ChordOrnament.Kind.modeled,
    )
    func everyKindDraws(_ kind: ChordOrnament.Kind) throws {
        let document = P.layout([P.chord(72, .whole, [ChordOrnament(kind: kind)])])
        let drawn = try #require(P.ornaments(document).first)
        if let own = SMuFLCodepoint.byName(kind.mscxToken) {
            #expect(drawn.codepoints == [own])
        } else {
            #expect(drawn.codepoints.count >= 4)
            let composed: [ChordOrnament.Kind] = [
                .prallMordent, .upPrall, .upMordent, .prallDown, .downMordent, .prallUp, .linePrall,
            ]
            #expect(composed.contains(kind))
        }
        #expect(drawn.ink.width > 0.5 * P.sp && drawn.ink.height > 0.5 * P.sp)
    }

    @Test("a composed ornament's pieces follow one another at their advances")
    func composedPiecesFollow() throws {
        let figure = try #require(LayoutEngine.ornamentFigure(
            ChordOrnament(kind: .prallMordent), sp: P.sp, mag: 1,
        ))
        let runs = figure.primitives.compactMap { primitive -> LayoutRichTextPositionedRun? in
            guard case let .run(run, _, _) = primitive else { return nil }
            return run
        }
        #expect(runs.count == 4)
        #expect(runs.map(\.baseline.x) == runs.map(\.baseline.x).sorted())
        #expect(Set(runs.map(\.baseline.y)) == [0])
        #expect(P.approximately(figure.ink.midX, 0))
    }

    @Test("a kind outside the palette is not drawn")
    func unknownIsNotDrawn() {
        let document = P.layout([P.chord(72, .whole, [
            ChordOrnament(kind: .unknown(subtype: "ornamentNotAThing")),
            // An SMuFL name the by-name table knows, but not a kind the model has.
            ChordOrnament(kind: .unknown(subtype: "ornamentComma")),
        ])])
        #expect(P.ornaments(document).isEmpty)
    }

    // MARK: - Side

    @Test("above for the first voice, below for the second, when no other voice sounds")
    func automaticSide() throws {
        let trill = ChordOrnament(kind: .trill)
        let document = P.layout([P.chord(72, .whole, [trill])])
        let top = try P.staffLines(document).top
        #expect(try #require(P.ornaments(document).first).ink.maxY < top)
        #expect(LayoutEngine.ornamentSide(trill, stem: .up, voiceIndex: 1, hasVoices: false) == .below)
        #expect(LayoutEngine.ornamentSide(trill, stem: .down, voiceIndex: 2, hasVoices: false) == .above)
        // With another voice under it, the stem decides rather than the voice.
        #expect(LayoutEngine.ornamentSide(trill, stem: .down, voiceIndex: 0, hasVoices: true) == .below)
        #expect(LayoutEngine.ornamentSide(trill, stem: .up, voiceIndex: 1, hasVoices: true) == .above)
    }

    @Test("with two voices each goes to its stem's side, clear of the stem")
    func voicesFollowTheStem() throws {
        let trill = ChordOrnament(kind: .trill)
        let document = P.layout(voices: [[P.chord(76, .half, [trill])], [P.chord(67, .half, [trill])]])
        let drawn = P.ornaments(document)
        #expect(drawn.count == 2)
        let upper = try #require(P.chords(document).first { $0.stem == .up })
        let lower = try #require(P.chords(document).first { $0.stem == .down })
        let upTip = try #require(upper.notes.first).origin.y - F.metrics.defaultStemLength
        let downTip = try #require(lower.notes.first).origin.y + F.metrics.defaultStemLength
        let staff = try P.staffLines(document)
        #expect(P.approximately(drawn[0].ink.maxY, min(staff.top, upTip) - P.distance))
        #expect(P.approximately(drawn[1].ink.minY, max(staff.bottom, downTip) + P.distance))
    }

    @Test("a stored anchor wins, then a stored placement")
    func storedSideWins() throws {
        var anchored = ChordOrnament(kind: .trill, anchor: .bottom)
        anchored.elementProperties.placement = .above
        var placed = ChordOrnament(kind: .trill)
        placed.elementProperties.placement = .below
        for ornament in [anchored, placed] {
            let document = P.layout([P.chord(72, .whole, [ornament])])
            let bottom = try P.staffLines(document).bottom
            #expect(try #require(P.ornaments(document).first).ink.minY > bottom)
        }
        let automatic = ChordOrnament(kind: .trill, anchor: .auto)
        #expect(LayoutEngine.ornamentSide(automatic, stem: .down, voiceIndex: 0, hasVoices: false) == .above)
    }

    // MARK: - Distances

    @Test("0.4 sp above the staff, the head and the stem, centered on the chord")
    func clearsTheChord() throws {
        let trill = ChordOrnament(kind: .trill)
        // C5: inside the staff, stem down — the staff is the limit.
        let inside = P.layout([P.chord(72, .half, [trill])])
        let insideInk = try #require(P.ornaments(inside).first).ink
        #expect(try P.approximately(insideInk.maxY, P.staffLines(inside).top - P.distance))
        #expect(try P.approximately(insideInk.midX, #require(F.chordNoteX(inside))))
        // G5: above the top line, stem down — the head is.
        let high = P.layout([P.chord(79, .half, [trill])])
        let headTop = try #require(F.chordNoteY(high)) - P.sp / 2
        #expect(try P.approximately(#require(P.ornaments(high).first).ink.maxY, headTop - P.distance))
        // A4 stem up: the stem's tip is.
        let low = P.layout([P.chord(69, .half, [trill])])
        #expect(try #require(P.chords(low).first).stem == .up)
        let tip = try #require(F.chordNoteY(low)) - F.metrics.defaultStemLength
        #expect(try P.approximately(#require(P.ornaments(low).first).ink.maxY, tip - P.distance))
        // A whole note has no stem.
        let whole = P.layout([P.chord(69, .whole, [trill])])
        #expect(try P.approximately(
            #require(P.ornaments(whole).first).ink.maxY, P.staffLines(whole).top - P.distance,
        ))
    }

    @Test("outside the articulation on its side, whatever the articulation's kind", arguments: [
        ChordArticulation.Kind.staccato, .accent, .marcato,
    ])
    func stacksOutsideArticulations(_ kind: ChordArticulation.Kind) throws {
        // Without autoplace, so nothing but the chord's own stack puts it there.
        var ornament = ChordOrnament(kind: .trill)
        ornament.elementProperties.autoplace = false
        let document = P.layout([P.chord(
            76, .half, [ornament], articulations: [ChordArticulation(kind: kind, anchor: .above)],
        )])
        let mark = try #require(P.articulationInk(document).first)
        let trill = try #require(P.ornaments(document).first)
        let staff = try P.staffLines(document)
        #expect(mark.midY < staff.top + 2 * P.sp)
        #expect(P.approximately(trill.ink.maxY, min(mark.minY, staff.top) - P.distance))
    }

    @Test("an articulation on the other side leaves it where it was")
    func ignoresArticulationsOnTheOtherSide() throws {
        let trill = ChordOrnament(kind: .trill)
        let plain = P.layout([P.chord(67, .half, [trill])])
        let marked = P.layout([P.chord(
            67, .half, [trill], articulations: [ChordArticulation(kind: .staccato, anchor: .below)],
        )])
        func height(_ document: LayoutDocument) throws -> CGFloat {
            try P.staffLines(document).top - #require(P.ornaments(document).first).ink.maxY
        }
        #expect(try P.approximately(height(plain), height(marked)))
    }

    @Test("two ornaments stack in order, 0.4 sp apart")
    func stacksOrnaments() throws {
        let drawn = P.ornaments(P.layout([P.chord(72, .whole, [
            ChordOrnament(kind: .turn), ChordOrnament(kind: .trill),
        ])]))
        try #require(drawn.count == 2)
        #expect(drawn[0].codepoints == [0xE567])
        #expect(P.approximately(drawn[1].ink.maxY, drawn[0].ink.minY - P.distance))
    }

    @Test("its accidentals are 0.6 the size, 0.35 sp off it and centered, and count as its ink")
    func accidentals() throws {
        let plain = try #require(LayoutEngine.ornamentFigure(ChordOrnament(kind: .turn), sp: P.sp, mag: 1))
        let marked = try #require(LayoutEngine.ornamentFigure(
            ChordOrnament(kind: .turn, accidentalAbove: .sharp, accidentalBelow: .flat), sp: P.sp, mag: 1,
        ))
        let runs = marked.primitives.compactMap { primitive -> LayoutRichTextPositionedRun? in
            guard case let .run(run, _, _) = primitive else { return nil }
            return run
        }
        try #require(runs.count == 3)
        #expect(P.approximately(runs[1].font.pointSize, 4 * P.sp * 0.6))
        let margin = 0.35 * P.sp
        let above = LayoutFigure(primitives: [marked.primitives[1]]).ink
        let below = LayoutFigure(primitives: [marked.primitives[2]]).ink
        #expect(P.approximately(above.maxY, plain.ink.minY - margin))
        #expect(P.approximately(below.minY, plain.ink.maxY + margin))
        #expect(P.approximately(above.midX, plain.ink.midX) && P.approximately(below.midX, plain.ink.midX))
        #expect(P.approximately(marked.ink.minY, above.minY) && P.approximately(marked.ink.maxY, below.maxY))
        // The accidental below is what the distance to the staff is measured from.
        let document = P.layout([P.chord(72, .whole, [ChordOrnament(kind: .turn, accidentalBelow: .flat)])])
        #expect(try P.approximately(
            #require(P.ornaments(document).first).ink.maxY, P.staffLines(document).top - P.distance,
        ))
    }
}
