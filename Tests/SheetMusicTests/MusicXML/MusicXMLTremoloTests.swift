import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// A note's `<tremolo>` is read as MuseScore's `addTremolo` reads it: one on the note alone is the chord's, and a
/// two-note tremolo's start and stop make a pair whose chords are written twice as long as they last. The import used
/// to read no `<tremolo>`, so both kinds were lost and a two-note tremolo's halves came out as quarters.
@Suite("MusicXML tremolos")
struct MusicXMLTremoloTests {
    private typealias F = DirectionFixtures

    /// A half written over a quarter's time — `<time-modification>` 2:1, the tremolo's 2.
    private static func pairNote(_ step: String, tremolo: String?) -> String {
        let mark = tremolo.map { "<notations><ornaments>\($0)</ornaments></notations>" } ?? ""
        return F.note(
            step, duration: 480, type: "half",
            extra: "<time-modification><actual-notes>2</actual-notes><normal-notes>1</normal-notes></time-modification>"
                + mark,
        )
    }

    private static func chords(_ score: Score) -> [Chord] {
        F.voice(score).elements.values.compactMap { element in
            if case let .chord(chord) = element { chord } else { nil }
        }
    }

    @Test("a two-note tremolo's start and stop make a pair, written as halves and lasting a quarter each")
    func twoNoteTremolo() throws {
        let score = try F.score(measures: [
            Self.pairNote("C", tremolo: #"<tremolo type="start">2</tremolo>"#)
                + Self.pairNote("E", tremolo: #"<tremolo type="stop">2</tremolo>"#) + F.half("G"),
        ])
        let chords = Self.chords(score)
        #expect(chords.map(\.tremolo) == [Tremolo(subtype: .r16, span: .between), nil, nil])
        #expect(chords.map(\.isWrittenDoubled) == [true, true, false])
        #expect(chords.map(\.duration) == [.quarter, .quarter, .half])
        #expect(chords.map(\.drawnDuration) == [.half, .half, .half])
        #expect(F.voice(score).tuplets.isEmpty)
    }

    @Test("a tremolo on the note alone is the chord's, with its marks")
    func singleTremolo() throws {
        let single = F.note(
            "C",
            duration: 960,
            type: "half",
            extra: #"<notations><ornaments><tremolo type="single">3</tremolo></ornaments></notations>"#,
        )
        let score = try F.score(measures: [single + F.half("D")])
        #expect(Self.chords(score).map(\.tremolo) == [Tremolo(subtype: .r32, span: .single), nil])
    }

    @Test("a stop with no start makes no pair")
    func strayStop() throws {
        let score = try F.score(measures: [
            Self.pairNote("C", tremolo: nil) + Self.pairNote("E", tremolo: #"<tremolo type="stop">1</tremolo>"#)
                + F.half("G"),
        ])
        let chords = Self.chords(score)
        #expect(chords.allSatisfy { $0.tremolo == nil && !$0.isWrittenDoubled })
    }
}
