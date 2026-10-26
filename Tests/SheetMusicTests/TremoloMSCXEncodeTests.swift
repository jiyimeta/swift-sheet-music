import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct TremoloMSCXEncodeTests {
    @Test func roundtrip_r16_single() throws {
        let original = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r16),
        )
        let node = original.encodeAsChord(eid: .invalid)
        let decoded = try Chord.decode(node)
        #expect(decoded.tremolo == original.tremolo)
    }

    /// A voice with a two-note tremolo: the start chord carries it (`span == .between`), the follower none.
    private static let pair = Voice(elements: [
        .chord(Chord(
            duration: .half, notes: [Note(pitch: 60, tpc: 14)], tremolo: Tremolo(subtype: .r8, span: .between),
        )),
        .chord(Chord(duration: .half, notes: [Note(pitch: 64, tpc: 18)], tremolo: nil)),
    ])

    /// The names of a chord's tremolo children, whichever MuseScore version names them.
    private static func tremoloTags(_ chord: XMLTreeNode) -> [String] {
        chord.children.map(\.name).filter { $0.hasPrefix("Tremolo") }
    }

    @Test("a two-note tremolo is MuseScore 4's <TremoloTwoChord> on its first chord alone, as MuseScore writes it")
    func pairOnTheFirstChordOnly() throws {
        let chords = try Self.pair.encode().all("Chord")
        #expect(chords.count == 2)
        #expect(chords[0].first("TremoloTwoChord")?.first("subtype")?.text == "c8")
        #expect(chords.map(Self.tremoloTags) == [["TremoloTwoChord"], []])
    }

    @Test("for MuseScore 3 the pair is a <Tremolo> on its first chord alone")
    func pairForMuseScore3() throws {
        let chords = try Self.pair.encode(options: MSCXEncoderOptions(targetVersion: .v3)).all("Chord")
        #expect(chords[0].first("Tremolo")?.first("subtype")?.text == "c8")
        #expect(chords.map(Self.tremoloTags) == [["Tremolo"], []])
    }

    @Test("a one-note tremolo is MuseScore 4's <TremoloSingleChord>, MuseScore 3's <Tremolo>")
    func singleTagPerVersion() {
        let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)], tremolo: Tremolo(subtype: .r16))
        #expect(chord.encodeAsChord(eid: .invalid).first("TremoloSingleChord")?.first("subtype")?.text == "r16")
        let v3 = chord.encodeAsChord(eid: .invalid, options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(v3.first("Tremolo")?.first("subtype")?.text == "r16")
    }

    @Test("a pair saved by MuseScore 4 or by this encoder reads back as one pair")
    func pairRoundTrips() throws {
        let decoded = try Voice.decode(Self.pair.encode())
        let tremolos = decoded.elements.values.map { element -> Tremolo? in
            if case let .chord(chord) = element { chord.tremolo } else { nil }
        }
        #expect(tremolos == [Tremolo(subtype: .r8, span: .between), nil])
    }

    @Test func roundtrip_traditional_strokeStyle() throws {
        let original = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r32, strokeStyle: .traditional),
        )
        let node = original.encodeAsChord(eid: .invalid)
        let decoded = try Chord.decode(node)
        #expect(decoded.tremolo?.strokeStyle == .traditional)
    }
}
