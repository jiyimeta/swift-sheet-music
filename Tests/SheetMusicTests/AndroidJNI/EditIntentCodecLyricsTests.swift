@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips, the discriminator pin and hand-mutated-wire refusals for the lyrics payload (intent 74, macOS
/// score-text-entry, spec 2026-09-07). Its own file, like `EditIntentCodecHarmonyTests`, because
/// `EditIntentCodecTests.swift` is past SwiftLint's 400-line budget already.
@Suite("EditIntentCodec — lyrics payload")
struct EditIntentCodecLyricsTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
    private static let otherSlot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 4)
    private static let thirdSlot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 5)

    /// An empty list, a single write, several writes landing as one undo step (one of them a removal, one a verse
    /// above zero, one a non-zero melisma), and every `Syllabic` case at least once — so a dropped list element, a
    /// truncated array or a mis-tagged flag cannot survive looking right.
    private static let cases: [EditIntent] = [
        .setLyricSyllables(writes: []),
        .setLyricSyllables(writes: [
            LyricSyllableWrite(location: slot, verse: 0, text: "la", syllabic: .single, ticks: 0),
        ]),
        .setLyricSyllables(writes: [
            LyricSyllableWrite(location: slot, verse: 0, text: "glo", syllabic: .begin, ticks: 0),
            LyricSyllableWrite(location: otherSlot, verse: 2, text: nil),
            LyricSyllableWrite(location: thirdSlot, verse: 1, text: "ri", syllabic: .middle, ticks: 480),
        ]),
        .setLyricSyllables(writes: [
            LyricSyllableWrite(location: slot, verse: 0, text: "a", syllabic: .end, ticks: 0),
        ]),
    ]

    @Test("every lyrics intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: the payload stays under 128 bytes at
    /// these small indices, so the case index is the second byte.
    @Test func `the wire discriminator is 74`() {
        let bytes = EditIntentCodec.encode(.setLyricSyllables(writes: []))
        #expect(bytes[1] == 74)
        #expect(bytes.count < 128)
    }

    /// A removal has one byte shape: `syllabic` and `ticks` are zeroed on encode and come back `.single` / `0`
    /// regardless of what the caller passed — the `SetChordSymbolIntentWire.harmonyType` rule
    /// (`EditIntentCodecHarmonyTests`'s "a removal zeroes the harmony type"). This is the house rule, not a
    /// defect: a removal write that carries a non-default `syllabic` / `ticks` does not survive round-trip
    /// identity, which `roundTrips` above never exercises because none of its cases pairs `text == nil` with a
    /// non-default `syllabic` or `ticks`.
    @Test func `a removal zeroes syllabic and ticks`() throws {
        let bytes = EditIntentCodec.encode(.setLyricSyllables(writes: [
            LyricSyllableWrite(location: Self.slot, verse: 1, text: nil, syllabic: .middle, ticks: 480),
        ]))
        #expect(try EditIntentCodec.decode(bytes) == .setLyricSyllables(writes: [
            LyricSyllableWrite(location: Self.slot, verse: 1, text: nil, syllabic: .single, ticks: 0),
        ]))
    }

    @Test func `a syllabic outside the table is refused`() {
        var wire = SetLyricSyllablesIntentWire(writes: [
            LyricSyllableWrite(location: Self.slot, verse: 0, text: "la"),
        ])
        wire.writes[0].syllabic = 4
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(4)) {
            try EditIntentCodec.decode(EditIntentWire.setLyricSyllables(wire).encodeToData())
        }
    }
}
