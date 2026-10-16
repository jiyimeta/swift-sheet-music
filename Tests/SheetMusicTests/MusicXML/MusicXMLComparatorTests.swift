import Foundation
@testable import SheetMusicCore
import Testing

/// The comparator the W8 fixtures are judged by: it sees staff text when asked, ignores MuseScore's arbitrary order
/// inside a run of untimed annotations when asked, and ignores line geometry (hook heights, dash lengths) that
/// MusicXML cannot carry when asked.
@Suite("MusicXML comparator")
struct MusicXMLComparatorTests {
    private static func score(lane: [PositionedSystemElement] = [], voice: [VoiceElement]) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: voice)])])],
            )],
            systemMeasures: [SystemMeasure(elements: lane)],
        )
    }

    private static let text = PositionedSystemElement(
        position: .start, element: .staffText(StaffText(text: "dolce")),
    )
    private static let quarter = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
    private static let dynamic = VoiceElement.dynamic(Dynamic(subtype: "p", velocity: 49))
    private static let wedgeEnd = VoiceElement.spanner(Spanner(kind: .hairpin, rawType: "HairPin", visible: false))

    @Test("staff text is compared unless the strip is switched on")
    func staffTextIsCompared() {
        let with = Self.score(lane: [Self.text], voice: [Self.quarter])
        let without = Self.score(voice: [Self.quarter])
        #expect(ScoreSemanticComparison.normalize(with) != ScoreSemanticComparison.normalize(without))
        var strip = ScoreSemanticComparison.Options()
        strip.stripsStaffText = true
        #expect(ScoreSemanticComparison.normalize(with, options: strip)
            == ScoreSemanticComparison.normalize(without, options: strip))
    }

    @Test("a run of untimed annotations compares equal in any order when asked")
    func annotationRunOrder() {
        let one = Self.score(voice: [Self.dynamic, Self.wedgeEnd, Self.quarter])
        let other = Self.score(voice: [Self.wedgeEnd, Self.dynamic, Self.quarter])
        #expect(ScoreSemanticComparison.normalize(one) != ScoreSemanticComparison.normalize(other))
        var sorted = ScoreSemanticComparison.Options()
        sorted.sortsAnnotationRuns = true
        #expect(ScoreSemanticComparison.normalize(one, options: sorted)
            == ScoreSemanticComparison.normalize(other, options: sorted))
    }

    @Test("sorting never moves an annotation across a chord")
    func sortingStopsAtChords() {
        let one = Self.score(voice: [Self.dynamic, Self.quarter, Self.wedgeEnd])
        let other = Self.score(voice: [Self.wedgeEnd, Self.quarter, Self.dynamic])
        var sorted = ScoreSemanticComparison.Options()
        sorted.sortsAnnotationRuns = true
        #expect(ScoreSemanticComparison.normalize(one, options: sorted)
            != ScoreSemanticComparison.normalize(other, options: sorted))
    }

    @Test("line geometry is ignored when asked")
    func lineGeometry() {
        var wide = Spanner(kind: .textLine, rawType: "TextLine")
        wide.lineProperties = Spanner.LineProperties(beginHookHeight: 1.9, endHookHeight: 1.9)
        var plain = Spanner(kind: .textLine, rawType: "TextLine")
        plain.lineProperties = Spanner.LineProperties()
        let one = Self.score(voice: [.spanner(wide), Self.quarter])
        let other = Self.score(voice: [.spanner(plain), Self.quarter])
        var ignoring = ScoreSemanticComparison.Options()
        ignoring.ignoresLineGeometry = true
        #expect(ScoreSemanticComparison.normalize(one, options: ignoring)
            == ScoreSemanticComparison.normalize(other, options: ignoring))
    }
}
