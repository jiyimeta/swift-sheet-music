import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// MSCX → MuseScore's MusicXML export → this importer, against the MSCX it started from. Not a full equivalence
/// (MusicXML carries less than MSCX): the tempo at every downbeat, the dynamics' subtypes and velocities, and what
/// each bar holds, by kind. Every delta is listed in `knownDeltas` with its reason; any other delta fails.
@Suite("MusicXML round trip through MuseScore's exporter")
struct MusicXMLRoundTripTests {
    private static let names = ["directions-all", "tempo-texts", "tempo-gradual"]

    /// "<name>:<measure index>" → why the two sides differ there, filled from the first measured run, only with deltas
    /// MuseScore's exporter (`EX` = `importexport/musicxml/internal/export/exportmusicxml.cpp`) explains.
    private static let knownDeltas: [String: String] = [
        "tempo-gradual:4": "the accelerando (m3 to the end of m4, factor 1.5) is exported as a bare text line: "
            + "ExportMusicXml::textLine (EX:5799-5911) writes a GradualTempoChange as <dashes> (words only for a "
            + "non-empty beginText, EX:5905-5909) with no <sound>, so nothing plays it; this bar is mid-accelerando",
        "tempo-gradual:5": "after the accelerando lost on export (EX:5799-5911): the original plays 80 x 1.5 = 120, "
            + "the export stays at 80",
        "tempo-gradual:6": "the original still holds 120 (its rall. has <play>0</play> and no later tempo resets it); "
            + "the export stays at 80 since the accelerando was lost (EX:5799-5911)",
        "tempo-texts:6": "a tempo text with <play>0</play> (quarter = 180): tempoSound (EX:5019-5029) writes "
            + "text->tempo() and never reads playTempoText, so the export plays <sound tempo=\"180\"/> where the "
            + "original keeps the previous metric modulation's 40",
    ]

    private static func original(_ name: String) throws -> Score {
        let source = name == "directions-all" ? "directions-all-infer" : name
        return try MSCXParser.parse(MSCXFixtureLoader.mscxData(source))
    }

    private static func exported(_ name: String) throws -> Score {
        let url = try #require(TestResources.url(forResource: "\(name)-export", withExtension: "musicxml"))
        return try MusicXMLParser.parse(Data(contentsOf: url))
    }

    private static func measureCount(_ score: Score) -> Int {
        score.parts.first?.staves.first?.measures.count ?? 0
    }

    @Test("the tempo at every downbeat survives", arguments: names)
    func tempoMapSurvives(name: String) throws {
        let before = try Self.original(name)
        let after = try Self.exported(name)
        #expect(Self.measureCount(before) == Self.measureCount(after))
        for index in 0 ..< Self.measureCount(before) where Self.knownDeltas["\(name):\(index)"] == nil {
            let one = before.effectiveQuarterBpm(at: .beat(measureIndex: index, tickInMeasure: 0))
            let two = after.effectiveQuarterBpm(at: .beat(measureIndex: index, tickInMeasure: 0))
            #expect(abs(one - two) < 0.01, "\(name) bar \(index): \(one) vs \(two)")
        }
    }

    /// What a bar's first voice and the system lane hold, by kind, in order — enough to see a lost or invented element.
    private static func shape(_ score: Score, measure: Int) -> [String] {
        var kinds: [String] = []
        for element in score.parts[0].staves[0].measures[measure].voices[0].elements.values {
            switch element {
            case let .dynamic(dynamic): kinds.append("dynamic:\(dynamic.subtype):\(dynamic.velocity)")
            case let .spanner(spanner) where !spanner.isEndMarker: kinds.append("spanner:\(spanner.kind.rawValue)")
            case .expression: kinds.append("expression")
            default: break
            }
        }
        for entry in score.systemMeasures[measure].elements.values {
            switch entry.element {
            case .tempo: kinds.append("tempo")
            case .staffText: kinds.append("staffText")
            case .rehearsalMark: kinds.append("rehearsal")
            default: break
            }
        }
        return kinds.sorted()
    }

    @Test("what each bar holds survives", arguments: ["directions-all"])
    func barsKeepTheirElements(name: String) throws {
        let before = try Self.original(name)
        let after = try Self.exported(name)
        for index in 0 ..< Self.measureCount(before) where Self.knownDeltas["\(name):\(index)"] == nil {
            #expect(Self.shape(before, measure: index) == Self.shape(after, measure: index), "\(name) bar \(index)")
        }
    }
}
