import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A `<Dynamic>` keeps what MuseScore wrote beside its subtype — its own `<text>`, `<play>`, `<veloChangeSpeed>` — and
/// saves them back in MuseScore's order (`TWrite::write(const Dynamic*)`, `rw/write/twrite.cpp:1288-1308`): `<play>`
/// and `<veloChangeSpeed>` after `<velocity>`, `<text>` last (`twrite.cpp:1344-1348`) — and never before `<subtype>`,
/// which MuseScore applies by resetting the text to the subtype's own (`Dynamic::setDynamicType`,
/// `dom/dynamic.cpp:230-240`).
@Suite("Dynamic text round trip")
struct DynamicTextRoundTripTests {
    private static func fixture() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics"))
    }

    /// The first dynamic of 1-based measure `number`.
    private static func dynamic(_ score: Score, measure number: Int) -> Dynamic? {
        for element in score.parts[0].staves[0].measures[number - 1].voices[0].elements.values {
            if case let .dynamic(dynamic) = element { return dynamic }
        }
        return nil
    }

    /// Each `<Dynamic>` of 1-based measure `number` in `data`, as its children's names (`<eid>` left out).
    private static func children(_ data: Data, measure number: Int) throws -> [[String]] {
        let root = try XMLTreeParser.parse(data)
        let staff = try #require(root.first("Score")?.first("Staff"))
        let voice = try #require(staff.all("Measure")[number - 1].first("voice"))
        return voice.all("Dynamic").map { dynamic in dynamic.children.map(\.name).filter { $0 != "eid" } }
    }

    @Test("a dynamic's own text is kept: plain words, runs with their glyphs, an other-dynamics word")
    func ownTextIsKept() throws {
        let score = try Self.fixture()
        let subito = try #require(Self.dynamic(score, measure: 2))
        #expect(subito.subtype == "p")
        #expect(subito.text == "subito p")
        #expect(subito.preservedTextMarkup == nil)
        let piu = try #require(Self.dynamic(score, measure: 3))
        #expect(piu.text == "più ")
        #expect(piu.richText?.lines == [[
            .text("più ", RichTextFormat()), .symbol(name: "dynamicForte", RichTextFormat()),
        ]])
        let dolce = try #require(Self.dynamic(score, measure: 4))
        #expect(dolce.subtype == "other-dynamics")
        #expect(dolce.text == "dolce")
        let poco = try #require(Self.dynamic(score, measure: 6))
        #expect(poco.richText?.lines.first?.first == .text("poco ", RichTextFormat(bold: true)))
        #expect(!poco.preservedMarkup.map(\.name).contains("text"))
    }

    @Test("a dynamic printing its subtype has no text and keeps nothing it does not model")
    func subtypeOnlyHasNoText() throws {
        let plain = try #require(Self.dynamic(Self.fixture(), measure: 1))
        #expect(plain.text == nil)
        #expect(plain.preservedTextMarkup == nil)
        #expect(plain.preservedMarkup.isEmpty)
    }

    @Test("<play> and <veloChangeSpeed> are read into the model")
    func playAndSpeedAreModeled() throws {
        let score = try Self.fixture()
        let muted = try #require(Self.dynamic(score, measure: 5))
        #expect(!muted.playsBack)
        #expect(muted.preservedMarkup.isEmpty)
        let slow = try #require(Self.dynamic(score, measure: 8))
        #expect(slow.velocityChangeSpeed == .slow)
        #expect(slow.preservedMarkup.isEmpty)
        let plain = try #require(Self.dynamic(score, measure: 1))
        #expect(plain.playsBack)
        #expect(plain.velocityChangeSpeed == .normal)
    }

    @Test("saving writes back what was read, in MuseScore's order")
    func savesWhatItRead() throws {
        let data = try MSCXEncoder.encode(Self.fixture())
        #expect(try Self.children(data, measure: 1) == [["subtype", "velocity"]])
        #expect(try Self.children(data, measure: 2) == [["subtype", "velocity", "text"]])
        #expect(try Self.children(data, measure: 5) == [["subtype", "velocity", "play"]])
        #expect(try Self.children(data, measure: 8) == [["subtype", "velocity", "veloChangeSpeed"]])
        let xml = try #require(String(bytes: data, encoding: .utf8))
        #expect(xml.contains("<text>subito p</text>"))
        #expect(xml.contains("<text>più <sym>dynamicForte</sym></text>"))
        #expect(xml.contains("<text><b>poco </b><sym>dynamicMezzo</sym><sym>dynamicForte</sym></text>"))
        #expect(xml.contains("<play>0</play>"))
        #expect(xml.contains("<veloChangeSpeed>slow</veloChangeSpeed>"))
    }

    @Test("an edited text saves as plain text: the stale formatting goes, the words stay")
    func editedTextSavesPlain() throws {
        var score = try Self.fixture()
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[2].voices[0].elements.updateValue(at: 0) { element in
                    guard case var .dynamic(dynamic) = element else { return }
                    dynamic.text = "più forte"
                    element = .dynamic(dynamic)
                }
            }
        }
        let xml = try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(xml.contains("<text>più forte</text>"))
        #expect(!xml.contains("<text>più <sym>dynamicForte</sym></text>"))
    }
}
