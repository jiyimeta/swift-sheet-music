import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGFloat`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

@Suite("LayoutEngine articulation emission")
struct LayoutArticulationTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Build a one-measure score whose single chord has `articulations`.
    /// `pitch` controls staff position (60 = middle C, treble; 71 = B
    /// just above the middle line). `tpc` should spell `pitch` correctly
    /// so the note lands on its real staff line (default 14 = C natural).
    private static func score(
        pitch: Int = 60,
        tpc: Int = 14,
        articulations: [ChordArticulation] = [],
    ) -> Score {
        let note = Note(pitch: pitch, tpc: tpc)
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([note]),
            articulations: articulations,
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff],
            )],
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func laidOut(_ s: Score) -> LayoutDocument {
        let opts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        )
        let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
        return LayoutEngine.layout(
            score: s, options: opts, availableWidth: natW,
        )
    }

    /// Pull the single articulation + chord from a single-measure
    /// single-staff document. Returns `nil` if not exactly one of each.
    @available(macOS 15.0, iOS 16.0, *)
    private static func soleArtAndChord(
        _ doc: LayoutDocument,
    ) -> (LayoutElement, LayoutElement)? {
        guard let measure = doc.systems.first?.measures.first
        else { return nil }
        var art: LayoutElement?
        var chord: LayoutElement?
        for el in measure.elements {
            if case .articulation = el {
                if art != nil { return nil }
                art = el
            }
            if case .chord = el {
                if chord != nil { return nil }
                chord = el
            }
        }
        guard let a = art, let c = chord else { return nil }
        return (a, c)
    }

    /// The Y at which the glyph's INK center renders. `origin.y` is the
    /// `.center` (typographic-frame) anchor; the layout shifts it inward by
    /// `ArticulationGlyphMetrics.inkCenterOffset` so the rendered ink lands
    /// on the intended reference. Tests assert against the rendered ink.
    private static func renderedInkY(
        _ el: LayoutElement, sp: CGFloat,
    ) -> CGFloat? {
        guard case let .articulation(kind, origin, isAbove) = el
        else { return nil }
        let cp = UInt16(truncatingIfNeeded: ArticulationGlyph.codepoint(
            kind: kind, isAbove: isAbove,
        ))
        return origin.y
            + ArticulationGlyphMetrics.inkCenterOffset(codepoint: cp) * sp
    }

    /// MuseScore recomputes a close-to-note articulation's side from the
    /// stem on load (default CHORD anchor), so the SymId `…Above`/`…Below`
    /// suffix carried in `art.anchor` must NOT drive placement. Whatever
    /// anchor is supplied, the glyph lands away from the stem.
    @Test("Side follows the stem, ignoring the anchor suffix")
    func sideFollowsStemNotAnchor() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // A low note (stem up → below) and a high note (stem down → above).
        for (pitch, tpc) in [(60, 14), (81, 17)] {
            var sides: Set<Bool> = []
            for anchor in [ChordArticulation.Anchor.above, .below, nil] {
                let doc = Self.laidOut(Self.score(
                    pitch: pitch, tpc: tpc,
                    articulations: [.init(kind: .staccato, anchor: anchor)],
                ))
                let (art, chord) = try #require(Self.soleArtAndChord(doc))
                guard case let .articulation(_, _, isAbove) = art
                else { Issue.record("not articulation"); return }
                guard case let .chord(_, _, stem, _, _, _, _, _, _, _, _) = chord
                else { Issue.record("not chord"); return }
                #expect(isAbove == (stem == .down))
                sides.insert(isAbove)
            }
            // All three anchors produced the same (stem-derived) side.
            #expect(sides.count == 1)
        }
    }

    /// Regression: a beamed chord's staccato must follow the BEAM's stem
    /// direction, not the note's standalone stem. A4 (below the middle
    /// line, standalone stem up) beamed to D5 (above, stem down) takes the
    /// group's single down-stem, so both staccatos go above. Before the
    /// beam-pass re-placement the A4 dot flipped below.
    @Test("Beamed staccato follows the beam's stem, not the per-chord stem")
    func beamedStaccatoFollowsBeam() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let pitches: [(Int, Int)] = [(69, 17), (74, 16)] // A4, D5
        let elems: [VoiceElement] = pitches.map { pitch, tpc in
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: pitch, tpc: tpc)]),
                articulations: [.init(kind: .staccato, anchor: nil)],
            ))
        }
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: elems)])])],
            )],
        )
        let doc = Self.laidOut(score)
        guard let measure = doc.systems.first?.measures.first
        else { Issue.record("no measure"); return }
        var stemIsDown: Set<Bool> = []
        var artIsAbove: Set<Bool> = []
        var beamed = false
        for el in measure.elements {
            if case let .chord(_, _, stem, _, _, _, isBeamed, _, _, _, _) = el {
                stemIsDown.insert(stem == .down)
                beamed = beamed || isBeamed
            }
            if case let .articulation(_, _, isAbove) = el {
                artIsAbove.insert(isAbove)
            }
        }
        #expect(beamed)
        // One beam → one stem direction shared by both chords.
        try #require(stemIsDown.count == 1)
        // Both staccatos sit on the side away from that single stem.
        #expect(artIsAbove.count == 1)
        #expect(artIsAbove.first == stemIsDown.first)
    }

    /// Close-to-note distance mirrors MuseScore's `downLine`/`upLine`
    /// formula: 1 sp into a space, 1.5 sp when the note is ON a staff line,
    /// and 1 sp once the note reaches the outer line or beyond.
    @Test("Close-to-note distance is staff-line aware")
    func closeToNoteDistance() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // (pitch, tpc, expected gap in sp), treble clef.
        let cases: [(Int, Int, CGFloat)] = [
            (71, 19, 1.5), // B4 middle line  → on a line
            (69, 17, 1.0), // A4 space        → in a space
            (67, 15, 1.5), // G4 line         → on a line
            (64, 18, 1.0), // E4 bottom line  → outer line
            (60, 14, 1.0), // C4 ledger line  → outside the staff
            (74, 16, 1.5), // D5 line (stem down, above) → on a line
            (77, 13, 1.0), // F5 top line (above)        → outer line
        ]
        for (pitch, tpc, expected) in cases {
            let doc = Self.laidOut(Self.score(
                pitch: pitch, tpc: tpc,
                articulations: [.init(kind: .staccato, anchor: nil)],
            ))
            let (art, chord) = try #require(Self.soleArtAndChord(doc))
            guard case .articulation = art
            else { Issue.record("not articulation"); return }
            guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = chord
            else { Issue.record("not chord"); return }
            let noteY = try #require(notes.first?.origin.y)
            let inkY = try #require(Self.renderedInkY(art, sp: doc.metrics.sp))
            let gap = abs(inkY - noteY) / doc.metrics.sp
            #expect(
                abs(gap - expected) < 0.02,
                "pitch \(pitch): gap \(gap) sp, expected \(expected) sp",
            )
        }
    }

    @Test("Marcato sits above even on a stem-up chord (Gould p.117)")
    func marcatoForcesAbove() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            pitch: 60, tpc: 14, // C4, stem up
            articulations: [.init(kind: .marcato, anchor: .below)],
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, _, isAbove) = art
        else { Issue.record("not articulation"); return }
        #expect(isAbove == true)
    }

    @Test("Accent on a stem-down chord is pushed past the top staff line")
    func outsideStaffPushAbove() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            pitch: 72, tpc: 14, // C5, above the middle line → stem down
            articulations: [.init(kind: .accent, anchor: nil)],
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, origin, isAbove) = art
        else { Issue.record("not articulation"); return }
        #expect(isAbove == true)
        guard let system = doc.systems.first,
              let staffOriginY = system.staffOrigins.first?.y
        else { Issue.record("no staff origin"); return }
        let sp = doc.metrics.sp
        let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
        let staffTopY = staffMidY - sp * 2
        #expect(origin.y <= staffTopY - sp * 0.5 + 0.001)
    }

    @Test("Accent on a stem-up chord is pushed past the bottom staff line")
    func outsideStaffPushBelow() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            pitch: 67, tpc: 15, // G4, below the middle line → stem up
            articulations: [.init(kind: .accent, anchor: nil)],
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, origin, isAbove) = art
        else { Issue.record("not articulation"); return }
        #expect(isAbove == false)
        guard let system = doc.systems.first,
              let staffOriginY = system.staffOrigins.first?.y
        else { Issue.record("no staff origin"); return }
        let sp = doc.metrics.sp
        let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
        let staffBottomY = staffMidY + sp * 2
        #expect(origin.y >= staffBottomY + sp * 0.5 - 0.001)
    }

    /// Regression for `Come_Together_…`: a staccato on a note inside the
    /// staff was yanked all the way to the staff edge instead of hugging
    /// the notehead.
    @Test("Staccato on an interior note hugs the note, not the staff edge")
    func staccatoHugsInteriorNote() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // B4 sits on the middle line, stem down → staccato above, 1.5 sp.
        let doc = Self.laidOut(Self.score(
            pitch: 71, tpc: 19,
            articulations: [.init(kind: .staccato, anchor: nil)],
        ))
        let (art, chord) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, origin, _) = art
        else { Issue.record("not articulation"); return }
        guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = chord
        else { Issue.record("not chord"); return }
        let noteY = try #require(notes.first?.origin.y)
        guard let system = doc.systems.first,
              let staffOriginY = system.staffOrigins.first?.y
        else { Issue.record("no staff origin"); return }
        let sp = doc.metrics.sp
        let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
        let staffTopY = staffMidY - sp * 2

        // Hugs the note (≤ 1.5 sp) rather than the staff edge (~2.5 sp).
        #expect(abs(origin.y - noteY) <= sp * 1.5 + 0.001)
        // Stays inside / just at the staff, not yanked clear of it.
        #expect(origin.y > staffTopY - sp * 0.5 + 0.001)
    }

    @Test("Two same-side close-to-note glyphs stack 1 sp apart")
    func stacking() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // C4, stem up → both glyphs land below and stack downward.
        let doc = Self.laidOut(Self.score(
            pitch: 60, tpc: 14,
            articulations: [
                .init(kind: .staccato, anchor: nil),
                .init(kind: .tenuto, anchor: nil),
            ],
        ))
        guard let measure = doc.systems.first?.measures.first
        else { Issue.record("no measure"); return }
        // Rendered ink centers stack exactly 1 sp apart (MuseScore stacks
        // the bbox centers, so per-glyph ink offsets must not skew it).
        let inkYs = measure.elements.compactMap { el in
            Self.renderedInkY(el, sp: doc.metrics.sp)
        }
        try #require(inkYs.count == 2)
        #expect(abs(abs(inkYs[0] - inkYs[1]) - doc.metrics.sp) < 0.01)
    }

    @Test("Unknown articulation kind emits no .articulation element")
    func unknownIsFiltered() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [
                .init(
                    kind: .unknown(subtype: "articAccentAbove"),
                    anchor: .above,
                ),
            ],
        ))
        guard let measure = doc.systems.first?.measures.first
        else { Issue.record("no measure"); return }
        let count = measure.elements.reduce(into: 0) { acc, el in
            if case .articulation = el { acc += 1 }
        }
        #expect(count == 0)
    }

    @Test("Kind mapping covers staccatissimo and tenuto")
    func kindMapping() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        for (input, expected) in [
            (
                ChordArticulation.Kind.staccatissimo,
                LayoutElement.ArticulationKind.staccatissimo,
            ),
            (.tenuto, .tenuto),
        ] {
            let doc = Self.laidOut(Self.score(
                articulations: [.init(kind: input, anchor: .above)],
            ))
            let (art, _) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(kind, _, _) = art
            else { Issue.record("not articulation"); return }
            #expect(kind == expected)
        }
    }
}
