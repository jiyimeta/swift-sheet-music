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

    /// Whether `one` and `other` normalize equal without the allowance and with it (`allow` switches it on).
    private static func equality(
        _ one: Score, _ other: Score, allow: (inout ScoreSemanticComparison.Options) -> Void,
    ) -> (without: Bool, with: Bool) {
        var options = ScoreSemanticComparison.Options()
        let without = ScoreSemanticComparison.normalize(one) == ScoreSemanticComparison.normalize(other)
        allow(&options)
        let with = ScoreSemanticComparison.normalize(one, options: options)
            == ScoreSemanticComparison.normalize(other, options: options)
        return (without, with)
    }

    private static func score(voices: [[VoiceElement]]) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: voices.map { Voice(elements: $0) })])],
            )],
            systemMeasures: [SystemMeasure()],
        )
    }

    @Test("the meta tags mscore's app writes are ignored when listed")
    func appWrittenMetaTags() {
        var saved = Self.score(voice: [Self.quarter])
        saved.metaTags["creationDate"] = "2026-10-17"
        saved.metaTags["platform"] = "Apple Macintosh"
        saved.metaTags["originalFormat"] = "xml"
        let result = Self.equality(saved, Self.score(voice: [Self.quarter])) {
            $0.ignoreMetaTagKeys = ScoreSemanticComparison.appWrittenMetaTagKeys
        }
        #expect(result.without == false)
        #expect(result.with == true)
    }

    @Test("a part's trackName is ignored when asked")
    func partTrackName() {
        var named = Self.score(voice: [Self.quarter])
        named.parts.mapValues { part in
            var copy = part
            copy.trackName = "Flute"
            return copy
        }
        let result = Self.equality(named, Self.score(voice: [Self.quarter])) { $0.ignoresPartTrackName = true }
        #expect(result.without == false)
        #expect(result.with == true)
    }

    @Test("a pedal's auto continue / end text places are ignored when asked, other values are not")
    func pedalAutoTextPlace() {
        func pedal(_ place: String) -> VoiceElement {
            .spanner(Spanner(kind: .pedal, rawType: "Pedal", payloadMarkup: [
                PreservedXML(name: "continueTextPlace", text: place), PreservedXML(name: "endTextPlace", text: place),
            ]))
        }
        let bare = Self.score(voice: [.spanner(Spanner(kind: .pedal, rawType: "Pedal")), Self.quarter])
        let auto = Self.equality(Self.score(voice: [pedal("auto"), Self.quarter]), bare) {
            $0.ignoresPedalAutoTextPlace = true
        }
        let left = Self.equality(Self.score(voice: [pedal("left"), Self.quarter]), bare) {
            $0.ignoresPedalAutoTextPlace = true
        }
        #expect(auto.without == false)
        #expect(auto.with == true)
        #expect(left.with == false)
    }

    @Test("a cresc. line's styled texts are ignored when asked, a wedge's are not")
    func lineHairpinStyledTexts() {
        func hairpin(_ subtype: Spanner.HairpinPayload.Subtype, text: String?) -> VoiceElement {
            .spanner(Spanner(
                kind: .hairpin, rawType: "HairPin", beginText: text,
                hairpin: Spanner.HairpinPayload(subtype: subtype), continueText: text,
            ))
        }
        let line = Self.equality(
            Self.score(voice: [hairpin(.crescLine, text: "cresc."), Self.quarter]),
            Self.score(voice: [hairpin(.crescLine, text: nil), Self.quarter]),
        ) { $0.ignoresLineHairpinStyledTexts = true }
        let wedge = Self.equality(
            Self.score(voice: [hairpin(.crescendo, text: "cresc."), Self.quarter]),
            Self.score(voice: [hairpin(.crescendo, text: nil), Self.quarter]),
        ) { $0.ignoresLineHairpinStyledTexts = true }
        #expect(line.without == false)
        #expect(line.with == true)
        #expect(wedge.with == false)
    }

    @Test("a fermata's placement is ignored when it is its voice's default, kept when it is not")
    func defaultFermataPlacement() {
        func fermata(_ placement: Placement?) -> VoiceElement {
            var fermata = Fermata(subtype: "fermataAbove")
            fermata.elementProperties.placement = placement
            return .fermata(fermata)
        }
        func twoVoices(_ first: Placement?, _ second: Placement?) -> Score {
            Self.score(voices: [[fermata(first), Self.quarter], [fermata(second), Self.quarter]])
        }
        let defaults = Self.equality(twoVoices(.above, .below), twoVoices(nil, nil)) {
            $0.ignoresDefaultFermataPlacement = true
        }
        let flipped = Self.equality(twoVoices(.below, .above), twoVoices(nil, nil)) {
            $0.ignoresDefaultFermataPlacement = true
        }
        #expect(defaults.without == false)
        #expect(defaults.with == true)
        #expect(flipped.with == false)
    }

    @Test("a voice's trailing end markers go before its bar line, identical neighbours collapsed, when asked")
    func trailingEndMarkers() {
        let pedalEnd = VoiceElement.spanner(Spanner(kind: .pedal, rawType: "Pedal", visible: false))
        let barLine = VoiceElement.barLine(BarLine(subtype: "end"))
        let museScore4 = Self.score(voice: [Self.quarter, pedalEnd, pedalEnd, barLine])
        let decoded = Self.score(voice: [Self.quarter, barLine, pedalEnd])
        let result = Self.equality(museScore4, decoded) { $0.normalizesTrailingEndMarkers = true }
        let midMeasure = Self.equality(
            Self.score(voice: [pedalEnd, Self.quarter, barLine]), Self.score(voice: [Self.quarter, barLine, pedalEnd]),
        ) { $0.normalizesTrailingEndMarkers = true }
        #expect(result.without == false)
        #expect(result.with == true)
        #expect(midMeasure.with == false)
    }

    @Test("a tempo compares at the 6 decimals MuseScore writes when asked; a different tempo stays different")
    func tempoFilePrecision() {
        func tempo(_ beatsPerSecond: Double) -> Score {
            let mark = PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: beatsPerSecond)))
            return Self.score(lane: [mark], voice: [Self.quarter])
        }
        let rounded = Self.equality(tempo(100.0 / 60.0), tempo(1.666667)) { $0.roundsTempoToFilePrecision = true }
        let other = Self.equality(tempo(100.0 / 60.0), tempo(1.666668)) { $0.roundsTempoToFilePrecision = true }
        #expect(rounded.without == false)
        #expect(rounded.with == true)
        #expect(other.with == false)
    }
}
