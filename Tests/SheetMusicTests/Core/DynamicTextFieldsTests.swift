@testable import SheetMusicCore
import Testing

/// What MuseScore writes on a dynamic beside its subtype — its own text, `<play>`, `<veloChangeSpeed>` — what the
/// dynamic prints from them, and what each does to identity: the text `SetDynamic` writes moves the fingerprint,
/// formatting included; the play flag and the change speed, which no edit writes, do not.
@Suite("Dynamic text fields")
struct DynamicTextFieldsTests {
    private static let subito = PreservedTextMarkup(xmlText: "subito <sym>dynamicPiano</sym>")

    private static func subitoP() -> Dynamic {
        Dynamic(subtype: "p", velocity: 49, text: "subito ", preservedTextMarkup: subito)
    }

    /// `fourQuarterRests` with `dynamic` before the first rest.
    private static func score(_ dynamic: Dynamic) -> Score {
        var score = EditingFixtures.fourQuarterRests()
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                var elements = staff.measures[0].voices[0].elements.values
                elements.insert(.dynamic(dynamic), at: 1)
                staff.measures[0].voices[0].elements = IdentifiedArray(elements)
            }
        }
        return score
    }

    private static func dynamic(in score: Score) -> Dynamic? {
        if case let .dynamic(dynamic) = score.parts[0].staves[0].measures[0].voices[0].elements.values[1] {
            return dynamic
        }
        return nil
    }

    @Test("a dynamic built in code prints its subtype, plays, and changes at the normal speed")
    func defaults() {
        let dynamic = Dynamic(subtype: "p", velocity: 49)
        #expect(dynamic.text == nil)
        #expect(dynamic.preservedTextMarkup == nil)
        #expect(dynamic.playsBack)
        #expect(dynamic.velocityChangeSpeed == .normal)
        #expect(dynamic.richText == nil)
        #expect(dynamic.displayedRichText == nil)
        #expect(dynamic.customXMLText == nil)
    }

    @Test("the change speed spells MuseScore's <veloChangeSpeed> values")
    func speedRawValues() {
        #expect(Dynamic.VelocityChangeSpeed(rawValue: "slow") == .slow)
        #expect(Dynamic.VelocityChangeSpeed(rawValue: "fast") == .fast)
        #expect(Dynamic.VelocityChangeSpeed.normal.rawValue == "normal")
    }

    @Test("what a dynamic prints: its runs while the markup is current, else its words")
    func displayedRichText() {
        var dynamic = Self.subitoP()
        let runs: [[RichTextRun]] = [[
            .text("subito ", RichTextFormat()), .symbol(name: "dynamicPiano", RichTextFormat()),
        ]]
        #expect(dynamic.richText?.lines == runs)
        #expect(dynamic.displayedRichText?.lines == runs)
        dynamic.text = "subito f"
        #expect(dynamic.richText == nil)
        #expect(dynamic.displayedRichText?.lines == [[.text("subito f", RichTextFormat())]])
    }

    @Test("its own text as MuseScore xml text: the markup while current, else the words escaped")
    func customXMLText() {
        var dynamic = Self.subitoP()
        #expect(dynamic.customXMLText == "subito <sym>dynamicPiano</sym>")
        dynamic.text = "a < b"
        #expect(dynamic.customXMLText == "a &lt; b")
        #expect(Dynamic(subtype: "p", velocity: 49, text: "subito p").customXMLText == "subito p")
    }

    @Test("its own text moves the fingerprint, formatting included; the play flag and change speed do not")
    func fingerprint() {
        let plain = Self.score(Dynamic(subtype: "p", velocity: 49)).stableFingerprint
        let words = Self.score(Dynamic(subtype: "p", velocity: 49, text: "subito ")).stableFingerprint
        let formatted = Self.score(Self.subitoP()).stableFingerprint
        #expect(words != plain)
        #expect(formatted != words)
        var silent = Dynamic(subtype: "p", velocity: 49)
        silent.playsBack = false
        silent.velocityChangeSpeed = .slow
        #expect(Self.score(silent).stableFingerprint == plain)
    }

    @Test("stripping preserved markup clears a dynamic's markup and keeps its words")
    func stripping() throws {
        let stripped = try #require(Self.dynamic(in: Self.score(Self.subitoP()).strippingPreservedMarkup()))
        #expect(stripped.preservedTextMarkup == nil)
        #expect(stripped.text == "subito ")
    }
}
