import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// A stem direction a file sets — a chord's `<StemDirection>`, a beam's, MusicXML's `<stem>` — is drawn, as MuseScore
/// draws it (`ChordLayout::computeUp`, `BeamLayout::layout1`); the model used to keep only the chord's, as preserved
/// markup, and the layout chose every direction itself.
@Suite("Stem directions a file sets")
struct StemDirectionOverrideTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - MSCX

    @Test("a chord's and a beam's <StemDirection> read into the model and write back in MuseScore's places")
    func mscxRoundTrip() throws {
        let note = "<Note><pitch>60</pitch><tpc>14</tpc></Note>"
        let voice = try Voice.decode(XMLTreeParser.parse(Data("""
        <voice>
          <Chord><durationType>quarter</durationType><StemDirection>down</StemDirection>\(note)</Chord>
          <Beam><StemDirection>up</StemDirection></Beam>
          <Chord><durationType>eighth</durationType>\(note)</Chord>
          <Chord><durationType>eighth</durationType>\(note)</Chord>
        </voice>
        """.utf8)))
        let chords = Self.chords(voice)
        #expect(chords.map(\.stemDirection) == [.down, nil, nil])
        #expect(chords.map(\.beamStemDirection) == [nil, .up, nil])
        #expect(chords[0].preservedMarkup.allSatisfy { $0.name != "StemDirection" })

        let model = Voice(elements: chords.map { .chord($0) })
        let encoded = try model.encode()
        let first = try #require(encoded.children.first { $0.name == "Chord" })
        let names = first.children.map(\.name)
        let direction = try #require(names.firstIndex(of: "StemDirection"))
        #expect(first.children[direction].text == "down")
        #expect(direction < (names.firstIndex(of: "Note") ?? -1))
        let beam = try #require(encoded.children.first { $0.name == "Beam" })
        #expect(beam.first("StemDirection")?.text == "up")
        let reread = try Voice.decode(encoded)
        #expect(Self.chords(reread).map(\.beamStemDirection) == [nil, .up, nil])
    }

    @Test("a grace chord keeps its <StemDirection> through a save")
    func graceKeepsItsDirection() throws {
        let note = "<Note><pitch>62</pitch><tpc>16</tpc></Note>"
        let voice = try Voice.decode(XMLTreeParser.parse(Data("""
        <voice>
          <Chord><acciaccatura/><durationType>eighth</durationType><StemDirection>down</StemDirection>\(note)</Chord>
          <Chord><durationType>quarter</durationType>\(note)</Chord>
        </voice>
        """.utf8)))
        let grace = try #require(Self.chords(voice).first?.graceNotesBefore.values.first)
        #expect(grace.preservedMarkup.contains { $0.name == "StemDirection" && $0.text == "down" })
    }

    // MARK: - Layout

    @Test("a chord's own direction wins over its notes' position")
    @available(macOS 15.0, iOS 16.0, *)
    func chordDirectionWins() {
        var low = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        low.stemDirection = .down
        var high = Chord(duration: .quarter, notes: [Note(pitch: 77, tpc: 13)])
        high.stemDirection = .up
        let plain = Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])
        #expect(Self.stems([[.chord(low), .chord(high), .chord(plain)]]) == [[.down, .up, .up]])
    }

    @Test("a chord's own direction wins over its voice's side in a measure split into voices")
    @available(macOS 15.0, iOS 16.0, *)
    func chordDirectionBeatsTheVoiceSide() {
        var top = Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)])
        top.stemDirection = .down
        let bottom = Chord(duration: .whole, notes: [Note(pitch: 55, tpc: 15)])
        #expect(Self.stems([[.chord(top)], [.chord(bottom)]]) == [[.down], [.down]])
    }

    @Test("a beam's direction sets every member's stem, over a member's own")
    @available(macOS 15.0, iOS 16.0, *)
    func beamDirectionWins() {
        var first = Self.eighth(60)
        first.beamStemDirection = .down
        var second = Self.eighth(62)
        second.stemDirection = .up
        #expect(Self.stems([[.chord(first), .chord(second), .chord(Self.half(64)), .chord(Self.quarter(64))]])
            .first?.prefix(2) == [.down, .down])
    }

    @Test("with no beam direction, a member's own steers its beam")
    @available(macOS 15.0, iOS 16.0, *)
    func memberDirectionSteersTheBeam() {
        var second = Self.eighth(62)
        second.stemDirection = .down
        #expect(Self.stems([[.chord(Self.eighth(60)), .chord(second), .chord(Self.half(64)), .chord(Self.quarter(64))]])
            .first?.prefix(2) == [.down, .down])
    }

    @Test("a two-note tremolo's chords share the first's direction, or else the second's")
    func tremoloPairSharesItsDirection() {
        var start = Self.half(60)
        start.tremolo = Tremolo(subtype: .r8, span: .between)
        var follower = Self.half(64)
        follower.stemDirection = .down
        let setBySecond: [VoiceElement] = [.chord(start), .chord(follower)]
        #expect(LayoutEngine.stemOverride(ofChordAt: 0, in: setBySecond) == .down)
        #expect(LayoutEngine.stemOverride(ofChordAt: 1, in: setBySecond) == .down)
        start.stemDirection = .up
        let setByBoth: [VoiceElement] = [.chord(start), .chord(follower)]
        #expect(LayoutEngine.stemOverride(ofChordAt: 0, in: setByBoth) == .up)
        #expect(LayoutEngine.stemOverride(ofChordAt: 1, in: setByBoth) == .up)
        start.stemDirection = nil
        follower.stemDirection = nil
        #expect(LayoutEngine.stemOverride(ofChordAt: 1, in: [.chord(start), .chord(follower)]) == nil)
    }

    // MARK: - Helpers

    private static func eighth(_ pitch: Int) -> Chord {
        Chord(duration: .eighth, notes: [Note(pitch: pitch, tpc: 14 + 2 * ((pitch - 60) / 2))])
    }

    private static func quarter(_ pitch: Int) -> Chord {
        Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 18)])
    }

    private static func half(_ pitch: Int) -> Chord {
        Chord(duration: .half, notes: [Note(pitch: pitch, tpc: 18)])
    }

    private static func chords(_ voice: Voice) -> [Chord] {
        voice.elements.values.compactMap { element in
            if case let .chord(chord) = element { chord } else { nil }
        }
    }

    /// Each voice's chord stems in a one-measure 4/4 score laid out at its natural width.
    @available(macOS 15.0, iOS 16.0, *)
    private static func stems(_ voices: [[VoiceElement]]) -> [[StemDirection]] {
        let score = Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: voices.map { Voice(elements: $0) })])],
        )])
        let doc = LayoutArticulationTests.laidOut(score)
        var stems: [Int: [StemDirection]] = [:]
        for element in doc.systems.first?.measures.first?.elements ?? [] {
            if case let .chord(_, _, stem, _, _, _, _, voiceIndex, _, _, _) = element {
                stems[voiceIndex, default: []].append(stem)
            }
        }
        return stems.keys.sorted().map { stems[$0] ?? [] }
    }
}
