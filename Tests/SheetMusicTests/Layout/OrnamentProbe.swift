#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// What the ornament layout suites share: one-bar scores carrying ornaments, and what a laid-out one drew.
enum OrnamentProbe {
    // Inside the type, as `AnnotationFixtures` does: a file-private alias could not appear in these internal
    // signatures, which the wasm build compiles against the portable types.
    #if !canImport(CoreGraphics)
        typealias CGFloat = SheetMusicLayout.CGFloat
        typealias CGPoint = SheetMusicLayout.CGPoint
        typealias CGRect = SheetMusicLayout.CGRect
    #endif

    private typealias F = AnnotationFixtures
    static let sp = F.sp
    static let distance = LayoutEngine.ornamentDistanceSp * F.sp

    static func chord(
        _ pitch: Int, _ duration: NoteDuration = .quarter, _ ornaments: [ChordOrnament] = [],
        articulations: [ChordArticulation] = [],
    ) -> VoiceElement {
        .chord(Chord(
            duration: duration, notes: ChordNotes([Note(pitch: pitch, tpc: tpc[pitch] ?? 14)]),
            articulations: articulations, ornaments: ornaments,
        ))
    }

    private static let tpc = [62: 16, 64: 18, 65: 13, 67: 15, 69: 17, 71: 19, 72: 14, 74: 16, 76: 18, 77: 13, 79: 15]

    static func layout(_ elements: [VoiceElement], showsInvisible: Bool = false) -> LayoutDocument {
        F.layout(F.score(elements), showsInvisible: showsInvisible)
    }

    static func layout(voices: [[VoiceElement]]) -> LayoutDocument {
        F.layout(Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano"),
            staves: [Staff(lineCount: 5, measures: [Measure(voices: voices.map { Voice(elements: $0) })])],
        )]))
    }

    struct Drawn {
        let figure: LayoutFigure
        let color: ScoreColor?
        /// What the figure names: the ornament's chord and kind.
        let anchor: VoiceElementID?
        let kind: ChordOrnament.Kind

        var ink: CGRect {
            figure.ink
        }

        /// The glyphs drawn, in order.
        var codepoints: [UInt32] {
            figure.primitives.compactMap { primitive in
                guard case let .run(run, _, _) = primitive,
                      case let .symbol(codepoint) = run.content
                else { return nil }
                return codepoint
            }
        }
    }

    static func ornaments(_ elements: [LayoutElement]) -> [Drawn] {
        elements.compactMap { element in
            guard case let .figure(.ornament(anchor, kind), figure, color, _) = element else { return nil }
            return Drawn(figure: figure, color: color, anchor: anchor, kind: kind)
        }
    }

    static func ornaments(_ document: LayoutDocument) -> [Drawn] {
        ornaments(document.systems.flatMap(\.measures).flatMap(\.elements))
    }

    struct DrawnChord {
        let notes: [LayoutChordNote]
        let stem: StemDirection
        let stemOrigin: CGPoint
        let isBeamed: Bool
    }

    static func chords(_ document: LayoutDocument) -> [DrawnChord] {
        F.elements(document).compactMap { element in
            guard case let .chord(notes, _, stem, origin, _, _, isBeamed, _, _, _, _) = element else { return nil }
            return DrawnChord(notes: notes, stem: stem, stemOrigin: origin, isBeamed: isBeamed)
        }
    }

    static func articulationInk(_ document: LayoutDocument) -> [CGRect] {
        F.elements(document).compactMap { element in
            guard case let .articulation(kind, origin, isAbove, _) = element else { return nil }
            return LayoutElementShape.smuflGlyphRect(
                codepoint: ArticulationGlyph.codepoint(kind: kind, isAbove: isAbove), center: origin, sp: sp,
            )
        }
    }

    /// The staff's top and bottom lines in the drawn elements' frame, read off the first drawn note — the system
    /// shifts a staff down by the room what stands above it takes.
    static func staffLines(_ document: LayoutDocument) throws -> (top: CGFloat, bottom: CGFloat) {
        let note = try #require(chords(document).first?.notes.first)
        let middle = note.origin.y + CGFloat(note.step) * sp / 2
        return (middle - 2 * sp, middle + 2 * sp)
    }

    static func approximately(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 0.01
    }
}
