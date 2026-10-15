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

/// What the W5 layout tests share: a fixture loader, a one-staff score builder, a layout call at the standard 28 pt
/// staff (sp = 7 pt) and probes that read the `.staffText` elements a document carries.
enum AnnotationFixtures {
    static let sp: CGFloat = 7
    static let metrics = StaffMetrics(staffSize: 28)
    static let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    /// One staff, one measure, one voice holding `elements`; `system` is the system lane.
    static func score(
        _ elements: [VoiceElement], system: [PositionedSystemElement] = [],
        instrument: Instrument = Instrument(id: "piano"),
    ) -> Score {
        Score(division: 480, parts: [Part(
            id: "P1", instrument: instrument,
            staves: [Staff(lineCount: 5, measures: [Measure(voices: [Voice(elements: elements)])])],
        )], systemMeasures: [SystemMeasure(elements: system)])
    }

    /// A whole-note chord on one pitch.
    static func whole(_ pitch: Int = 72, tpc: Int = 14) -> VoiceElement {
        .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: pitch, tpc: tpc)])))
    }

    static func load(_ name: String) throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
    }

    static func layout(_ score: Score, showsInvisible: Bool = false) -> LayoutDocument {
        var options = ScoreViewOptions(staffSize: 28)
        options.showsInvisibleElements = showsInvisible
        return LayoutEngine.layout(score: score, options: options, availableWidth: 900)
    }

    /// Every element of the document, measure by measure (visible first, then the hidden ones the options asked for).
    static func elements(_ document: LayoutDocument) -> [LayoutElement] {
        document.systems.flatMap(\.measures).flatMap(\.drawnElements)
    }

    struct StaffTextProbe {
        let text: String
        let origin: CGPoint
        let style: TextStyleType
        let placement: TextPlacementMetadata?
        let richText: LayoutRichText?
        let measure: Int
    }

    /// The `.staffText` elements, in layout order, with the measure index they were emitted in.
    static func staffTexts(_ document: LayoutDocument) -> [StaffTextProbe] {
        document.systems.flatMap(\.measures).flatMap { measure in
            measure.drawnElements.compactMap { element -> StaffTextProbe? in
                guard case let .staffText(text, origin, _, style, _, placement, _, _, richText) = element else {
                    return nil
                }
                return StaffTextProbe(
                    text: text, origin: origin, style: style, placement: placement, richText: richText,
                    measure: measure.measureIndex,
                )
            }
        }
    }

    /// The x of the first note of the nth chord element, measure-local.
    static func chordNoteX(_ document: LayoutDocument, nth: Int = 0) -> CGFloat? {
        let chords = elements(document).compactMap { element -> CGFloat? in
            guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
            return notes.first?.origin.x
        }
        return chords.indices.contains(nth) ? chords[nth] : nil
    }
}
