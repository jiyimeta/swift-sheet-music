import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML direction texts")
struct MusicXMLDirectionTextTests {
    private typealias F = DirectionFixtures
    private typealias Found = (position: MeasurePosition, text: StaffText, staff: StaffAddress?)

    private static func staffTexts(_ score: Score, measure: Int = 0) -> [Found] {
        F.lane(score, measure: measure).compactMap { entry -> Found? in
            guard case let .staffText(text) = entry.element else { return nil }
            return (entry.position, text, entry.originalStaff)
        }
    }

    @Test("plain words are a staff text at the bar start, on the first staff")
    func plainWordsAreStaffText() throws {
        let body = F.direction(F.words("_ _ _"), attributes: "placement=\"above\"") + F.fourQuarters
        let texts = try Self.staffTexts(F.score(measures: [body]))
        #expect(texts.count == 1)
        #expect(texts.first?.text.text == "_ _ _")
        #expect(texts.first?.text.isSystemText == false)
        #expect(texts.first?.position == MeasurePosition.start)
        #expect(texts.first?.staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
    }

    @Test("system=\"only-top\" makes a system text")
    func systemOnlyTop() throws {
        let body = F.direction(F.words("Solo"), attributes: "system=\"only-top\"") + F.fourQuarters
        let texts = try Self.staffTexts(F.score(measures: [body]))
        #expect(texts.count == 1)
        #expect(texts.first?.text.isSystemText == true)
    }

    @Test("italic words below the staff are an Expression, in the voice at their tick")
    func italicBelowIsAnExpression() throws {
        let words = F.words("dolce", attributes: "font-style=\"italic\"")
        let body = F.quarter("C") + F.direction(words, attributes: "placement=\"below\"")
            + F.quarter("D") + F.quarter("E") + F.quarter("F")
        let score = try F.score(measures: [body])
        let found = F.expressions(in: F.voice(score))
        #expect(found.map(\.tick) == [480])
        #expect(found.first?.expression.text == "dolce")
        #expect(Self.staffTexts(score).isEmpty)
    }

    @Test("<sound pizzicato> makes a play-technique annotation even with inference off")
    func soundTechnique() throws {
        let body = F.direction(F.words("x"), "<sound pizzicato=\"yes\"/>") + F.fourQuarters
        let texts = try Self.staffTexts(F.score(measures: [body], infer: false))
        #expect(texts.first?.text.annotation == .playTechnique(.pizzicato, playsBack: true))
    }

    @Test("a technique read from the words needs inference", arguments: [true, false])
    func inferredTechnique(infer: Bool) throws {
        let body = F.direction(F.words("pizz.")) + F.fourQuarters
        let texts = try Self.staffTexts(F.score(measures: [body], infer: infer))
        #expect(texts.count == 1)
        let annotation = texts.first?.text.annotation
        #expect((annotation != nil) == infer)
        if infer {
            #expect(annotation == .playTechnique(.pizzicato, playsBack: true))
        }
    }

    @Test("sticking letters are a Sticking only when inferring", arguments: [true, false])
    func stickingWords(infer: Bool) throws {
        let body = F.direction(F.words("RLRL")) + F.fourQuarters
        let score = try F.score(measures: [body], infer: infer)
        #expect(F.stickings(in: F.voice(score)).count == (infer ? 1 : 0))
        #expect(Self.staffTexts(score).count == (infer ? 0 : 1))
    }

    @Test("with inference off, rit. and Allegro are plain staff texts and nothing else is made")
    func inferenceOffKeepsWordsPlain() throws {
        let body = F.direction(F.words("Allegro")) + F.quarter("C") + F.direction(F.words("rit.")) + F.quarter("D")
            + F.quarter("E") + F.quarter("F")
        let score = try F.score(measures: [body], infer: false)
        #expect(Self.staffTexts(score).map(\.text.text) == ["Allegro", "rit."])
        #expect(F.spanners(in: F.voice(score)).isEmpty)
        var tempoCount = 0
        for entry in F.lane(score) {
            if case .tempo = entry.element { tempoCount += 1 }
        }
        #expect(tempoCount == 0)
    }

    @Test("a color attribute reaches the element")
    func colorAttribute() throws {
        let body = F.direction(F.words("Solo", attributes: "color=\"#FF0000\"")) + F.fourQuarters
        let texts = try Self.staffTexts(F.score(measures: [body]))
        #expect(texts.first?.text.color == ScoreColor(red: 255, green: 0, blue: 0, alpha: 255))
    }

    /// The Expression a direction makes, with `attributes` on `<direction>` and `wordsAttributes` on `<words>`.
    private static func expression(
        _ attributes: String, wordsAttributes: String = "", partName: String? = nil,
    ) throws -> ExpressionText? {
        let words = F.words("dolce", attributes: "font-style=\"italic\"" + wordsAttributes)
        let body = F.direction(words, attributes: attributes) + F.fourQuarters
        return try F.expressions(in: F.voice(F.score(measures: [body], partName: partName))).first?.expression
    }

    @Test("an Expression carries MuseScore's <direction>down</direction>, as it is only made below")
    func expressionDirection() throws {
        let down = [PreservedXML(name: "direction", text: "down")]
        #expect(try Self.expression("placement=\"below\"")?.preservedMarkup == down)
        #expect(try Self.expression("placement=\"below\"", partName: "Soprano")?.preservedMarkup == down)
        #expect(try Self.expression("", wordsAttributes: " default-y=\"-80\"")?.preservedMarkup == down)
    }

    @Test("a color is #RRGGBB or #AARRGGBB of hex digits only; a sign is not a digit")
    func colorRejectsNonHexDigits() {
        #expect(MusicXMLColor.parse("#-1ffff") == nil)
        #expect(MusicXMLColor.parse("#+1ffff") == nil)
        #expect(MusicXMLColor.parse("#FF00zz") == nil)
        #expect(MusicXMLColor.parse("#00ff00") == ScoreColor(red: 0, green: 255, blue: 0, alpha: 255))
        #expect(MusicXMLColor.parse("#8000ff00") == ScoreColor(red: 0, green: 255, blue: 0, alpha: 128))
    }
}
