@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// The decision `MusicXmlParserDirection::direction` takes about a direction's words (`P2:3518-3614`), as a table.
@Suite("MusicXML words classifier")
struct MusicXMLWordsClassifierTests {
    struct Row: Sendable, CustomTestStringConvertible {
        var words: String
        var placement: String? = "above"
        var topStaff = true
        var soundTempo = 0.0
        var system = false
        var infer = true
        var technique: PlayingTechnique?
        var expected: MusicXMLTextKind

        var testDescription: String {
            "\(words) → \(expected)"
        }
    }

    private static let rows: [Row] = [
        Row(words: "Allegro", expected: .tempoText),
        Row(words: "dolce", expected: .tempoText),
        Row(words: "a tempo", expected: .tempoText),
        Row(words: "Allegro", topStaff: false, expected: .staffText),
        Row(words: "Allegro", placement: "below", expected: .staffText),
        Row(words: "<i>Allegro</i>", expected: .staffText),
        Row(words: "Allegro", infer: false, expected: .staffText),
        Row(words: "Allegro", soundTempo: 100, expected: .tempoText),
        Row(words: "Solo", soundTempo: 100, expected: .tempoText),
        Row(words: "rit.", expected: .tempoLine(.ritardando)),
        Row(words: "accel. poco a poco", expected: .tempoLine(.accelerando)),
        Row(words: "rit.", topStaff: false, expected: .staffText),
        Row(words: "rit.", infer: false, expected: .staffText),
        Row(words: "pizz.", expected: .playTechnique(.pizzicato)),
        // `getPlayingTechnique` lower-cases the words and drops `.,;:` before it scans its table (P2:5013-5014).
        Row(words: "Pizz.", expected: .playTechnique(.pizzicato)),
        Row(words: "con sord.", expected: .playTechnique(.mute)),
        Row(words: "senza sord.", expected: .playTechnique(.open)),
        // The table's first rows name palm mute as no technique, ahead of "mute" (P2:5019-5020).
        Row(words: "palm mute", expected: .staffText),
        Row(words: "pizz.", infer: false, expected: .staffText),
        Row(words: "x", infer: false, technique: .pizzicato, expected: .playTechnique(.pizzicato)),
        Row(words: "<i>dolce</i>", placement: "below", expected: .expression),
        Row(words: "<i>dolce</i>", placement: "below", infer: false, expected: .expression),
        Row(words: "Solo", system: true, expected: .systemText),
        Row(words: "RLRL", expected: .sticking),
        Row(words: "RLRL", infer: false, expected: .staffText),
        Row(words: "Solo", expected: .staffText),
    ]

    @Test("words become the element MuseScore makes of them", arguments: rows)
    func classifies(_ row: Row) {
        let traits = MusicXMLTextTraits(
            xmlText: row.words, placement: row.placement, isScoreTopStaff: row.topStaff, hasMetronome: false,
            soundTempo: row.soundTempo, isSystemDirection: row.system, soundTechnique: row.technique, infers: row.infer,
        )
        #expect(MusicXMLWordsClassifier.classify(traits) == row.expected)
    }

    private static let lineTypes: [(String, GradualTempoChangeType)] = [
        ("rit.", .ritardando), ("poco rit.", .ritardando), ("accel.", .accelerando), ("rall.", .rallentando),
        ("allargando", .allargando), ("calando", .calando), ("lentando", .lentando), ("morendo", .morendo),
        ("precipitando", .precipitando), ("smorz.", .smorzando), ("stringendo", .stringendo), ("slower", .undefined),
    ]

    @Test("a tempo line's type follows its words (`getTempoChangeTypeFromString`, P2:3374-3400)", arguments: lineTypes)
    func lineType(words: String, expected: GradualTempoChangeType) {
        #expect(MusicXMLWordsClassifier.tempoLineType(for: words) == expected)
    }
}
