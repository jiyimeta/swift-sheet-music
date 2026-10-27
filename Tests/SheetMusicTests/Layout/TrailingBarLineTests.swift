@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// A bar's end gets the usual line unless a voice ends the bar with a bar line of its own, drawn or hidden. A bar
/// line inside the bar used to count as that end, so a measure with a dashed line in its middle lost its end bar line,
/// and a hidden end bar line had a visible one drawn over it where MuseScore draws nothing.
@Suite("Trailing bar line")
struct TrailingBarLineTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let quarter = VoiceElement.chord(
        Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)])),
    )

    /// Two 4/4 bars, the first holding `first`, the second four quarters.
    private static func layout(_ first: [VoiceElement], showsInvisible: Bool = false) -> LayoutDocument {
        let opening: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")), .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ]
        let measures = [
            Measure(voices: [Voice(elements: opening + first)]),
            Measure(voices: [Voice(elements: Array(repeating: quarter, count: 4))]),
        ]
        let score = Score(
            division: 480,
            parts: [Part(id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: measures)])],
        )
        return LayoutEngine.layout(
            score: score, options: ScoreViewOptions(showsInvisibleElements: showsInvisible), availableWidth: 800,
        )
    }

    /// The first bar's bar lines, drawn or (with `invisible`) hidden, as subtype and role.
    private static func barLines(_ doc: LayoutDocument, invisible: Bool = false) -> [String] {
        guard let measure = doc.systems.first?.measures.first else { return [] }
        return (invisible ? measure.invisibleElements : measure.elements).compactMap { element in
            guard case let .barLine(subtype, _, _, _, role) = element else { return nil }
            return "\(subtype ?? "normal") \(role)"
        }
    }

    @Test("a bar line inside the bar leaves the bar its end line")
    func middleBarLineKeepsTheEnd() {
        let middle = VoiceElement.barLine(BarLine(subtype: "dashed"))
        let doc = Self.layout([Self.quarter, middle, Self.quarter, Self.quarter, Self.quarter])
        #expect(Self.barLines(doc) == ["dashed explicit", "normal trailing"])
    }

    @Test("a hidden end bar line draws nothing in its place, and is laid out among the hidden elements when shown")
    func hiddenEndBarLineDrawsNothing() {
        let hidden = BarLine(visible: false)
        let elements = Array(repeating: Self.quarter, count: 4) + [.barLine(hidden)]
        #expect(Self.barLines(Self.layout(elements)).isEmpty)
        let shown = Self.layout(elements, showsInvisible: true)
        #expect(Self.barLines(shown).isEmpty)
        #expect(Self.barLines(shown, invisible: true) == ["normal explicit"])
    }

    @Test("a bar with no bar line of its own gets the usual one")
    func plainBarGetsTheUsualLine() {
        #expect(Self.barLines(Self.layout(Array(repeating: Self.quarter, count: 4))) == ["normal trailing"])
    }
}
