@testable import SheetMusicCore
import Testing

/// The fields MuseScore writes beside a tempo's number — its text, `<followText>`, `<type>`, `<play>` and the children
/// nothing models — and what each does to identity: the four `SetTempo` writes move the fingerprint, source-only
/// markup does not, and stripping preserved markup clears a tempo's two bags.
@Suite("Tempo text fields")
struct TempoTextFieldsTests {
    private static func score(_ tempo: Tempo) -> Score {
        var score = EditingFixtures.fourQuarterRests()
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(tempo)),
        ])]
        return score
    }

    private static func tempo(in score: Score) -> Tempo? {
        guard case let .tempo(tempo)? = score.systemMeasures.values.first?.elements.values.first?.element else {
            return nil
        }
        return tempo
    }

    private static let boldAllegro = PreservedTextMarkup(
        content: [.element(PreservedTextMarkup.Element(name: "b", content: [.characters("Allegro")]))],
        derivedText: "Allegro",
    )

    @Test("a tempo built in code is derived, follows its text, plays and states a tempo")
    func defaults() {
        let tempo = Tempo(beatsPerSecond: 2)
        #expect(tempo.text == nil)
        #expect(tempo.preservedTextMarkup == nil)
        #expect(tempo.followText)
        #expect(tempo.textType == .normal)
        #expect(tempo.playsBack)
        #expect(tempo.preservedMarkup.isEmpty)
    }

    @Test("the text type spells MuseScore's <type> values")
    func textTypeRawValues() {
        #expect(TempoTextType(rawValue: "aTempo") == .aTempo)
        #expect(TempoTextType(rawValue: "tempoPrimo") == .tempoPrimo)
        #expect(TempoTextType.normal.rawValue == "normal")
    }

    @Test("each field SetTempo writes besides the number moves the fingerprint", arguments: 0 ..< 4)
    func fieldsMoveFingerprint(field: Int) {
        var tempo = Tempo(beatsPerSecond: 2)
        switch field {
        case 0: tempo.text = "Allegro"
        case 1: tempo.followText = false
        case 2: tempo.textType = .aTempo
        default: tempo.playsBack = false
        }
        #expect(Self.score(tempo).stableFingerprint != Self.score(Tempo(beatsPerSecond: 2)).stableFingerprint)
    }

    @Test("source-only markup does not move the fingerprint")
    func sourceMarkupIsNotHashed() {
        var tempo = Tempo(beatsPerSecond: 2)
        tempo.preservedTextMarkup = Self.boldAllegro
        tempo.preservedMarkup = [PreservedXML(name: "musicSymbolSize", text: "18")]
        #expect(Self.score(tempo).stableFingerprint == Self.score(Tempo(beatsPerSecond: 2)).stableFingerprint)
    }

    @Test("stripping preserved markup clears a tempo's two bags and keeps its text")
    func strippingClearsTempoBags() throws {
        var tempo = Tempo(beatsPerSecond: 2, text: "Allegro", preservedTextMarkup: Self.boldAllegro)
        tempo.preservedMarkup = [PreservedXML(name: "musicSymbolSize", text: "18")]
        let stripped = try #require(Self.tempo(in: Self.score(tempo).strippingPreservedMarkup()))
        #expect(stripped.preservedTextMarkup == nil)
        #expect(stripped.preservedMarkup.isEmpty)
        #expect(stripped.text == "Allegro")
    }

    @Test("the rich text is read only while the markup still describes the text")
    func richTextIsReadWhileCurrent() {
        var tempo = Tempo(beatsPerSecond: 2, text: "Allegro", preservedTextMarkup: Self.boldAllegro)
        #expect(tempo.richText?.lines == [[.text("Allegro", RichTextFormat(bold: true))]])
        tempo.text = "Andante"
        #expect(tempo.richText == nil)
    }
}
