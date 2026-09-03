@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips, discriminator pins and hand-mutated-wire refusals for the spanner payloads (intents 62…72,
/// edit-command parity group 6, spec 2026-09-02). Its own file, like `EditIntentCodecRangeTests` /
/// `…MarkTests`, because `EditIntentCodecTests.swift` is past SwiftLint's 400-line budget already.
@Suite("EditIntentCodec — spanner payloads")
struct EditIntentCodecSpannerTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let start = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
    private static let end = VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 1, elementIndex: 0)
    private static let range = VoiceElementRange(start: start, end: end)

    /// Both shapes of every optional, a multi-element and an empty `[Int32]`, an ottava subtype inside the table
    /// and one outside it — so a dropped flag, a mis-framed list or a silently-defaulted enum cannot look right.
    private static let cases: [EditIntent] = [
        .setSlur(over: range),
        .setHairpin(over: range, subtype: .dimLine),
        .setPedal(over: range),
        .setVolta(over: range, endings: [1, 2, 3], text: "1.–3."),
        .setVolta(over: range, endings: [], text: nil),
        .setOttava(over: range, subtype: .twentyTwoMB),
        .setOttava(over: range, subtype: .other("8vbAlta")),
        .setTextLine(over: range, text: "poco a poco"),
        .setTextLine(over: range, text: nil),
        .setTrill(over: range, type: .prallprall),
        .setVibrato(over: range, type: .sawtoothWide),
        .setPalmMute(over: range),
        .setLetRing(over: range),
        .removeSpanner(at: start, kind: .letRing),
        .removeSpanner(at: start, kind: .other),
    ]

    @Test("every spanner intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: every payload here stays under 128 bytes
    /// at these small indices — the volta is read with an EMPTY list for exactly that reason, which also pins the
    /// empty-array framing.
    @Test func `the wire discriminators stay where they were`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let slot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let range = VoiceElementRange(start: slot, end: slot)
        #expect(EditIntentCodec.encode(.setSlur(over: range))[1] == 62)
        #expect(EditIntentCodec.encode(.setHairpin(over: range, subtype: .crescendo))[1] == 63)
        #expect(EditIntentCodec.encode(.setPedal(over: range))[1] == 64)
        #expect(EditIntentCodec.encode(.setVolta(over: range, endings: [], text: nil))[1] == 65)
        #expect(EditIntentCodec.encode(.setOttava(over: range, subtype: .eightVA))[1] == 66)
        #expect(EditIntentCodec.encode(.setTextLine(over: range, text: nil))[1] == 67)
        #expect(EditIntentCodec.encode(.setTrill(over: range, type: .trill))[1] == 68)
        #expect(EditIntentCodec.encode(.setVibrato(over: range, type: .guitarVibrato))[1] == 69)
        #expect(EditIntentCodec.encode(.setPalmMute(over: range))[1] == 70)
        #expect(EditIntentCodec.encode(.setLetRing(over: range))[1] == 71)
        #expect(EditIntentCodec.encode(.removeSpanner(at: slot, kind: .slur))[1] == 72)
        #expect(EditIntentCodec.encode(.setVolta(over: range, endings: [], text: nil)).count < 128)
    }

    /// The codec's first scalar array. An empty list must survive as an empty list (not as nil, not as [0]), and
    /// a long list must keep its order and its negative values' zig-zag encoding.
    @Test func `the volta endings list keeps its shape`() throws {
        for endings in [[], [1], [1, 2], [-1, 0, 7, 128]] as [[Int]] {
            let intent = EditIntent.setVolta(over: Self.range, endings: endings, text: nil)
            guard case let .setVolta(_, decoded, _) = try EditIntentCodec.decode(EditIntentCodec.encode(intent))
            else { Issue.record("expected a setVolta"); return }
            #expect(decoded == endings)
        }
    }

    @Test func `an unknown trill or vibrato spelling is refused`() {
        var trill = SetTrillIntentWire(range: Self.range, type: .trill)
        trill.type = "mordent"
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setTrill(trill).encodeToData())
        }
        var vibrato = SetVibratoIntentWire(range: Self.range, type: .guitarVibrato)
        vibrato.type = "wobble"
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setVibrato(vibrato).encodeToData())
        }
    }

    @Test func `an out-of-table hairpin subtype and an unknown spanner kind are refused`() {
        var hairpin = SetHairpinIntentWire(range: Self.range, subtype: .crescendo)
        hairpin.subtype = 4
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setHairpin(hairpin).encodeToData())
        }
        var removal = RemoveSpannerIntentWire(location: Self.start, kind: .slur)
        removal.kind = "Tie"
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.removeSpanner(removal).encodeToData())
        }
    }
}
