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
        let node = original.encodeAsChord()
        let decoded = try Chord.decode(node)
        #expect(decoded.tremolo == original.tremolo)
    }

    @Test func roundtrip_c8_pair_emits_on_both_chords() throws {
        // A voice with a two-note tremolo: start.span = .between, follower
        // has tremolo == nil. Encode the voice → expect both <Chord>
        // elements to carry <Tremolo><subtype>c8</subtype>.
        let start = Chord(
            duration: .half,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .half,
            notes: [Note(pitch: 64, tpc: 18)],
            tremolo: nil,
        )
        let voice = Voice(elements: [.chord(start), .chord(follower)])
        let voiceNode = try voice.encode()
        let chords = voiceNode.all("Chord")
        #expect(chords.count == 2)
        #expect(chords[0].first("Tremolo")?.first("subtype")?.text == "c8")
        #expect(chords[1].first("Tremolo")?.first("subtype")?.text == "c8")
    }

    @Test func roundtrip_traditional_strokeStyle() throws {
        let original = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            tremolo: Tremolo(subtype: .r32, strokeStyle: .traditional),
        )
        let node = original.encodeAsChord()
        let decoded = try Chord.decode(node)
        #expect(decoded.tremolo?.strokeStyle == .traditional)
    }
}
