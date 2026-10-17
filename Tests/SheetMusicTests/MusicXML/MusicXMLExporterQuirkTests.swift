import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML exporter quirks")
struct MusicXMLExporterQuirkTests {
    private typealias F = DirectionFixtures

    private static func tempos(_ score: Score) -> [Tempo] {
        F.lane(score).compactMap { entry -> Tempo? in
            guard case let .tempo(tempo) = entry.element else { return nil }
            return tempo
        }
    }

    private static let softwareNames: [(String, MusicXMLExporterSoftware)] = [
        ("Sibelius 7", .sibelius), ("Dolet 6.6 for Sibelius", .dolet6), ("Dolet 8 for Sibelius", .dolet8),
        ("Finale 2014", .finale), ("Dorico 4", .dorico), ("MuseScore 4", .other),
    ]

    @Test("the software element names the exporter, case-insensitively (P1:409-426)", arguments: softwareNames)
    func detect(name: String, expected: MusicXMLExporterSoftware) {
        #expect(MusicXMLExporterSoftware.detect(softwareText: name) == expected)
    }

    private static let finaleWords: [(String, String)] = [
        ("π", "pp"), ("P", "mp"), ("F", "mf"), ("ƒ", "ff"), ("Ï", "fff"), ("S", "sf"), ("ß", "sfz"), ("Z", "fz"),
        ("Í", "fp"),
    ]

    @Test("Finale's dynamic-font letters are read as dynamics (P2:4516-4526)", arguments: finaleWords)
    func finaleDynamics(words: String, subtype: String) throws {
        let body = F.direction(F.words(words)) + F.fourQuarters
        let score = try F.score(measures: [body], software: "Finale 2014")
        #expect(F.dynamics(in: F.voice(score)).map(\.dynamic.subtype) == [subtype])
    }

    @Test("other exporters keep those letters as words")
    func otherExportersKeepLetters() throws {
        let body = F.direction(F.words("S")) + F.fourQuarters
        let score = try F.score(measures: [body], software: "MuseScore 4")
        #expect(F.dynamics(in: F.voice(score)).isEmpty)
        #expect(F.lane(score).count == 1)
    }

    private static let sibeliusRows: [(String, String, Double)] = [
        ("Lingering  q = c. 40", "Lingering <sym>metNoteQuarterUp</sym> = c. 40", 40),
        ("q. = c. 78", "<sym>metNoteQuarterUp</sym><sym>space</sym><sym>metAugmentationDot</sym> = c. 78", 117),
        ("Andante (q = c. 90)", "Andante (<sym>metNoteQuarterUp</sym> = c. 90)", 90),
        ("e. = c. 78", "<sym>metNote8thUp</sym><sym>space</sym><sym>metAugmentationDot</sym> = c. 78", 58.5),
        ("h = c. 78", "<sym>metNoteHalfUp</sym> = c. 78", 156),
        ("w = c. 78", "<sym>metNoteWhole</sym> = c. 78", 312),
    ]

    @Test("Sibelius metronome words become a tempo text with symbols (P2:4901-4974)", arguments: sibeliusRows)
    func sibeliusMetronome(words: String, xml: String, bpm: Double) throws {
        let body = F.direction(F.words(words, attributes: "font-weight=\"bold\"")) + F.fourQuarters
        let score = try F.score(measures: [body], software: "Sibelius 7")
        let tempo = try #require(Self.tempos(score).first)
        #expect(tempo.preservedTextMarkup?.xmlText == xml)
        #expect(abs(tempo.beatsPerSecond - bpm / 60) < 1e-9)
        #expect(tempo.followText)
    }

    @Test("a MetTimes metronome word is a quarter-note tempo (P2:4919-4929)")
    func metTimes() throws {
        let words = F.words("Œ = 90", attributes: "font-family=\"MetTimes Plain\"")
        let score = try F.score(measures: [F.direction(words) + F.fourQuarters])
        let tempo = Self.tempos(score).first
        #expect(tempo?.text == nil)
        #expect(abs((tempo?.beatsPerSecond ?? 0) - 1.5) < 1e-9)
    }

    @Test("with inference off, Finale letters and Sibelius metronome words stay words (P2:4511, 4903)")
    func quirksNeedInference() throws {
        let finale = try F.score(
            measures: [F.direction(F.words("S")) + F.fourQuarters], software: "Finale 2014", infer: false,
        )
        #expect(F.dynamics(in: F.voice(finale)).isEmpty)
        #expect(F.lane(finale).count == 1)
        let sibelius = try F.score(
            measures: [F.direction(F.words("q. = c. 78")) + F.fourQuarters], software: "Sibelius 7", infer: false,
        )
        #expect(Self.tempos(sibelius).isEmpty)
        #expect(F.lane(sibelius).count == 1)
    }

    private static let ottavaStops: [(String, [Int])] = [("MuseScore 4", [480, 960]), ("Sibelius 7", [480, 1440])]

    @Test("a Sibelius ottava stop waits for the next note (P2:3787-3794, 2829-2833)", arguments: ottavaStops)
    func sibeliusOttava(software: String, ticks: [Int]) throws {
        let c5 = F.quarter("C", octave: 5)
        let start = F.direction("<octave-shift type=\"down\" size=\"8\" number=\"1\"/>")
        let stop = F.direction("<octave-shift type=\"stop\" size=\"8\" number=\"1\"/>")
        let body = c5 + start + c5 + stop + c5 + c5
        let score = try F.score(measures: [body], software: software)
        #expect(F.spanners(in: F.voice(score)).map(\.tick) == ticks)
    }
}
