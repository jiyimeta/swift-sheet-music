import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Writing slurs whose begin or end is a grace chord, so that MuseScore reads them back.
///
/// MuseScore pairs a slur's two `<Spanner>` halves by comparing locations (`ConnectorInfo::connect`): the begin
/// side's `<next>` added to its own position must equal the end chord's position, grace index included, and the end
/// side's `<prev>` the other way round. So it is not enough for this package's own reader to find the slur again —
/// each half has to sit in the right `<Chord>` with the `<grace>` MuseScore expects. The fixture test checks exactly
/// that against MuseScore's own bytes.
@Suite("Grace-note slur round trip")
struct GraceSlurRoundTripTests {
    /// Every `<Chord>` of the re-encoded fixture — graces included, in file order — carries the same slur halves, with
    /// the same `<location>` children, as the file MuseScore wrote.
    @Test("MuseScore's grace/slur fixture is written back with MuseScore's own slur halves")
    func fixtureSlurHalvesMatchMuseScore() throws {
        let data = try MSCXFixtureLoader.mscxData("slur_grace_selectionfilter")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(data))
        let original = try Self.slurHalves(in: data)
        let written = try Self.slurHalves(in: encoded)
        #expect(original.count == 4 * 10) // four bars of six chords and four graces
        #expect(written == original)
    }

    @Test("the fixture's slurs survive decode → encode → decode")
    func fixtureModelRoundTrips() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("slur_grace_selectionfilter"))
        let reread = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(Self.slurBegins(in: reread) == Self.slurBegins(in: score))
        #expect(Self.slurBegins(in: score).count == 12)
    }

    /// The common case: `<next><location/></next>` on the grace — the `<location>` is required, MuseScore reads a bare
    /// `<next/>` as no begin at all — and `<prev><location><grace>0</grace></location></prev>` on the principal note.
    @Test("a grace slurred into its own principal writes MuseScore's zero-offset pair")
    func graceIntoItsOwnPrincipal() throws {
        let score = try MSCXParser.parse(Data(GraceSlurDecodeTests.graceIntoPrincipal.utf8))
        let encoded = try MSCXEncoder.encode(score)
        let chords = try Self.voiceChords(in: encoded)
        #expect(chords.count == 2)
        let begin = try #require(chords[0].first("Spanner"))
        #expect(!begin.all("Slur").isEmpty)
        #expect(try #require(begin.first("next")?.first("location")).children.isEmpty)
        let end = try #require(chords[1].first("Spanner")?.first("prev")?.first("location"))
        #expect(end.children.map(\.name) == ["grace"])
        #expect(end.first("grace")?.text == "0")
        // The slur halves sit after `<durationType>` and ahead of the grace tag, where MuseScore writes them.
        let names = chords[0].children.map(\.name)
        let spannerIndex = try #require(names.firstIndex(of: "Spanner"))
        #expect(try spannerIndex > #require(names.firstIndex(of: "durationType")))
        #expect(try spannerIndex < #require(names.firstIndex(of: "acciaccatura")))
        #expect(try Self.slurBegins(in: MSCXParser.parse(encoded)) == Self.slurBegins(in: score))
    }

    /// A chord slurred into its own after-grace: the grace is written ahead of the chord, so its `<prev>` has to be
    /// placed before the begin side has been reached — the run is resolved as a unit.
    @Test("a chord slurred into its own after-grace places the end marker in the grace")
    func chordIntoItsOwnAfterGrace() throws {
        let score = try MSCXParser.parse(Data(GraceSlurDecodeTests.chordIntoAfterGrace.utf8))
        let encoded = try MSCXEncoder.encode(score)
        let chords = try Self.voiceChords(in: encoded)
        #expect(chords.count == 2)
        let end = try #require(chords[0].first("Spanner")?.first("prev")?.first("location"))
        #expect(end.children.isEmpty)
        let next = try #require(chords[1].first("Spanner")?.first("next")?.first("location"))
        #expect(next.children.map(\.name) == ["grace"])
        #expect(next.first("grace")?.text == "0")
        #expect(try Self.slurBegins(in: MSCXParser.parse(encoded)) == Self.slurBegins(in: score))
    }

    /// A run of two before- and two after-graces, slurred within the run every way the grace index can tell apart:
    /// the after-run is written back to front (`Chord.mscxFileOrderedGraces`), so the after-grace that SOUNDS first
    /// is MuseScore grace 3, and a `<grace>` computed from the list index alone would name the wrong one.
    @Test("slurs within a mixed grace run keep their ends")
    func mixedRunRoundTrips() throws {
        func grace(_ type: GraceType, _ pitch: Int, slurTo target: Int?? = nil) -> GraceChord {
            GraceChord(
                graceType: type, duration: .sixteenth, notes: [Note(pitch: pitch, tpc: 14)],
                spanners: target.map { [Spanner(kind: .slur, rawType: "Slur", nextGraceIndex: $0)] } ?? [],
            )
        }
        // before[0] → before[1] (grace 1); before[1] → the chord; the chord → after[0] (grace 3);
        // after[0] → after[1] (grace 2).
        let chord = Chord(
            duration: .half, notes: [Note(pitch: 72, tpc: 14)],
            graceNotesBefore: [grace(.acciaccatura, 74, slurTo: 1), grace(.acciaccatura, 76, slurTo: .some(nil))],
            graceNotesAfter: [grace(.grace16after, 71, slurTo: 2), grace(.grace16after, 69)],
            spanners: [Spanner(kind: .slur, rawType: "Slur", nextGraceIndex: 3)],
        )
        let score = Self.score(voice: [
            .chord(chord), .chord(Chord(duration: .half, notes: [Note(pitch: 72, tpc: 14)])),
        ])
        let encoded = try MSCXEncoder.encode(score)
        let reread = try MSCXParser.parse(encoded)
        #expect(Self.slurBegins(in: reread) == Self.slurBegins(in: score))
        // Every begin got its end marker: four `<prev>` halves in the run, one per slur.
        let prevs = try Self.voiceChords(in: encoded).flatMap { $0.all("Spanner") }.filter { !$0.all("prev").isEmpty }
        #expect(prevs.count == 4)
    }

    // MARK: - Helpers

    /// One `<Chord>` of the voice stream (grace or not) reduced to its slur halves: `next` / `prev` and the
    /// `<location>` children as `name=text`.
    struct Half: Equatable, CustomStringConvertible {
        let side: String
        let location: [String]
        var description: String {
            "\(side)(\(location.joined(separator: ",")))"
        }
    }

    static func slurHalves(in data: Data) throws -> [[Half]] {
        try voiceChords(in: data).map { chord in
            chord.all("Spanner").filter { $0.attributes["type"] == "Slur" }.map { spanner in
                let side = spanner.all("next").isEmpty ? "prev" : "next"
                let location = spanner.first(side)?.first("location")?.children ?? []
                return Half(side: side, location: location.map { "\($0.name)=\($0.text)" })
            }
        }
    }

    static func voiceChords(in data: Data) throws -> [XMLTreeNode] {
        let staff = try #require(XMLTreeParser.parse(data).first("Score")?.first("Staff"))
        return staff.all("Measure").flatMap { measure in
            measure.all("voice").flatMap { $0.all("Chord") }
        }
    }

    /// Every slur begin in the score, keyed by where it starts — the bar and the chord's ordinal in it, since the
    /// encoder may drop a redundant signature ahead of the first chord and so shift element indices.
    static func slurBegins(in score: Score) -> [String] {
        var out: [String] = []
        for (_, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                let chords = measure.voices[0].elements.values.compactMap { element -> Chord? in
                    guard case let .chord(chord) = element else { return nil }
                    return chord
                }
                for (ordinal, chord) in chords.enumerated() {
                    let place = "m\(measureIndex)c\(ordinal)"
                    out += chord.spanners.map { "\(place) chord \(describe($0))" }
                    for (index, grace) in chord.graceNotesBefore.enumerated() {
                        out += grace.spanners.map { "\(place) before\(index) \(describe($0))" }
                    }
                    for (index, grace) in chord.graceNotesAfter.enumerated() {
                        out += grace.spanners.map { "\(place) after\(index) \(describe($0))" }
                    }
                }
            }
        }
        return out
    }

    private static func describe(_ spanner: Spanner) -> String {
        let fractions = spanner.nextFractionsOffset.map { "\($0.numerator)/\($0.denominator)" } ?? "-"
        return "\(spanner.rawType) m\(spanner.nextMeasuresOffset) f\(fractions) g\(spanner.nextGraceIndex ?? -1)"
    }

    static func score(voice elements: [VoiceElement]) -> Score {
        ScoreEditor(score: Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: elements)])])],
        )])).score
    }
}
