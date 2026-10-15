import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// F6.8: `<rootCase>` / `<bassCase>` are MuseScore's `NoteCaseType` (AUTO -1, CAPITAL 0, LOWER 1, UPPER 2) and the
/// case drawn is `Harmony::rootRenderCase` / `bassRenderCase` (`dom/harmony.cpp:611-680`).
@Suite("Chord symbol case")
struct HarmonyCaseTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func harmony(
        name: String, root: Int? = 14, bass: Int? = nil,
        rootCase: NoteCase = .auto, bassCase: NoteCase = .auto,
    ) -> Harmony {
        Harmony(name: name, rootTpc: root, rootCase: rootCase, bassTpc: bass, bassCase: bassCase)
    }

    @Test("the numbers are MuseScore's")
    func numbers() throws {
        func decode(_ value: String) throws -> NoteCase {
            // MuseScore 4.60's shape (`TWrite::write(Harmony*)`): the case is a direct child, the name and root sit
            // in `<harmonyInfo>`.
            let xml = """
            <Harmony><harmonyType>0</harmonyType><rootCase>\(value)</rootCase>\
            <harmonyInfo><name>m</name><root>14</root></harmonyInfo></Harmony>
            """
            let node = try XMLTreeParser.parse(Data(xml.utf8))
            return try Harmony.decode(node).rootCase
        }
        #expect(try decode("-1") == .auto)
        #expect(try decode("0") == .capitalize)
        #expect(try decode("1") == .lower)
        #expect(try decode("2") == .upper)
    }

    @Test("only lower and upper are written, as 1 and 2")
    func encodeOmitsCapitalAndAuto() {
        let lower = Self.harmony(name: "m", rootCase: .lower).encode(eid: .invalid)
        #expect(lower.first("rootCase")?.text == "1")
        let upper = Self.harmony(name: "m", bassCase: .upper).encode(eid: .invalid)
        #expect(upper.first("bassCase")?.text == "2")
        // `XMLTreeNode.first(_:)` is a child lookup, not `Sequence.first(where:)`, so the
        // contains_over_first_not_nil rule fires as a false positive.
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(Self.harmony(name: "m").encode(eid: .invalid).first("rootCase") == nil)
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(Self.harmony(name: "m", rootCase: .capitalize).encode(eid: .invalid).first("rootCase") == nil)
    }

    @Test("the four style flags are read and still saved")
    func styleFlags() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("chord-symbol-case"))
        #expect(score.style.chordSymbolCase.lowerCaseMinorChords)
        #expect(score.style.chordSymbolCase.automaticCapitalization)
        let text = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(text.contains("<lowerCaseMinorChords>1</lowerCaseMinorChords>"))
    }

    @Test("the style flags are read off <Style> in both directions")
    func nonDefaultStyleFlagsAreRead() throws {
        let xml = """
        <Style><automaticCapitalization>0</automaticCapitalization><lowerCaseBassNotes>1</lowerCaseBassNotes>\
        <allCapsNoteNames>1</allCapsNoteNames></Style>
        """
        let style = try ScoreStyle.decode(style: XMLTreeParser.parse(Data(xml.utf8)))
        #expect(!style.chordSymbolCase.automaticCapitalization)
        #expect(style.chordSymbolCase.lowerCaseBassNotes)
        #expect(style.chordSymbolCase.allCapsNoteNames)
        #expect(!style.chordSymbolCase.lowerCaseMinorChords)
    }

    @Test("automatic capitalization ignores the stored case")
    func automaticCapitalizationIgnoresStoredCase() {
        let lower = Self.harmony(name: "7", rootCase: .lower, bassCase: .lower)
        #expect(HarmonyRendering.displayedName(for: lower, style: .museScoreDefaults) == "C7")
        var manual = ChordSymbolCaseStyle.museScoreDefaults
        manual.automaticCapitalization = false
        #expect(HarmonyRendering.displayedName(for: lower, style: manual) == "c7")
    }

    @Test("lowerCaseMinorChords lowers the root of minor, diminished and half-diminished names only")
    func minorChordsLowerTheRoot() {
        var style = ChordSymbolCaseStyle.museScoreDefaults
        style.lowerCaseMinorChords = true
        func shown(_ name: String) -> String {
            HarmonyRendering.displayedName(for: Self.harmony(name: name), style: style)
        }
        #expect(shown("m7") == "cm7")
        #expect(shown("min") == "cmin")
        #expect(shown("-7") == "c-7")
        #expect(shown("dim") == "cdim")
        #expect(shown("maj7") == "Cmaj7")
        #expect(shown("M7") == "CM7")
        #expect(shown("7") == "C7")
        #expect(shown("") == "C")
        // The quality token ends at a space or any of `()[],/\` as well as a digit (`ParsedChord::parse`,
        // `dom/chordlist.cpp:584-585, 602-605`): "m" before the slash is minor, "maj" before it is major.
        #expect(shown("m/E") == "cm/E")
        #expect(shown("maj7/E") == "Cmaj7/E")
        #expect(shown("m E") == "cm E")
    }

    @Test("lowerCaseBassNotes lowers the bass; allCapsNoteNames keeps letters upper")
    func bassAndAllCaps() {
        var style = ChordSymbolCaseStyle.museScoreDefaults
        style.lowerCaseBassNotes = true
        #expect(HarmonyRendering.displayedName(for: Self.harmony(name: "7", bass: 16), style: style) == "C7/d")
        style = .museScoreDefaults
        style.allCapsNoteNames = true
        #expect(
            HarmonyRendering.displayedName(for: Self.harmony(name: "7", bass: 16, rootCase: .lower), style: style)
                == "C7/D",
        )
    }

    @Test("the fixture draws its minor chords lower-case")
    func fixtureLayout() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("chord-symbol-case"))
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
        let texts = document.systems.flatMap(\.measures).flatMap(\.elements).compactMap { element -> String? in
            // `.harmony(LayoutHarmony)`: the drawn text is the text runs joined (accidental runs have empty content).
            if case let .harmony(layoutHarmony) = element {
                return layoutHarmony.runs.map(\.content).joined()
            }
            return nil
        }
        #expect(texts.contains { $0.hasPrefix("cm7") })
        #expect(texts.contains { $0.hasPrefix("Cmaj7") })
    }

    private static func harmonyTexts(in document: LayoutDocument) -> [String] {
        document.systems.flatMap(\.measures).flatMap(\.elements).compactMap { element -> String? in
            if case let .harmony(layoutHarmony) = element { return layoutHarmony.runs.map(\.content).joined() }
            return nil
        }
    }

    /// The width cache keys a bar by the chord-symbol case style (`LayoutEngine+Packing`): a bar whose chord symbol
    /// changes width with the case must not be taken from the cache laid out under the other style.
    @Test("a warm layout cache follows a changed chord-symbol case style")
    func warmCacheFollowsTheCaseStyle() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("chord-symbol-case"))
        #expect(score.style.chordSymbolCase.lowerCaseMinorChords)
        let cache = LayoutCache()
        let options = ScoreViewOptions()
        let lower = LayoutEngine.layout(score: score, options: options, availableWidth: 800, cache: cache)
        #expect(Self.harmonyTexts(in: lower).contains { $0.hasPrefix("cm7") })
        score.style.chordSymbolCase.lowerCaseMinorChords = false
        let warm = LayoutEngine.layout(score: score, options: options, availableWidth: 800, cache: cache)
        let cold = LayoutEngine.layout(score: score, options: options, availableWidth: 800)
        #expect(Self.harmonyTexts(in: warm).contains { $0.hasPrefix("Cm7") })
        #expect(!Self.harmonyTexts(in: warm).contains { $0.hasPrefix("cm7") })
        // A stale width entry would pack the bars as the lower-case layout did; the cold layout is the reference.
        #expect(warm == cold)
        #expect(warm.chordSymbolCase == score.style.chordSymbolCase)
    }
}
