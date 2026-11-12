import Foundation
@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips and the discriminator pin for the score-credits payload (intent 80).
@Suite("EditIntentCodec — score info payload")
struct EditIntentCodecScoreInfoTests {
    /// Every field, written and cleared — the `hasText` pair is what separates "set to empty" from "clear", and a
    /// projection that collapsed them would pass a written-only round trip.
    private static let cases: [EditIntent] = ScoreInfoWrite.Field.allCases.flatMap { field in
        [
            EditIntent.setScoreInfo(writes: [ScoreInfoWrite(field: field, text: "x")]),
            EditIntent.setScoreInfo(writes: [ScoreInfoWrite(field: field, text: nil)]),
        ]
    } + [
        .setScoreInfo(writes: []),
        .setScoreInfo(writes: [
            ScoreInfoWrite(field: .title, text: "Sonata"),
            ScoreInfoWrite(field: .composer, text: "作曲者"),
            ScoreInfoWrite(field: .arranger, text: nil),
        ]),
    ]

    @Test("every score-info intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: the payload stays under 128 bytes at these
    /// small indices, so the case index is the second byte.
    ///
    /// **84, not 80.** This intent was written against a catalogue that ended at 79 and the properties-inspector
    /// project landed 80…83 first. The index is decided by position in `EditIntentWire`, so the renumber was a
    /// merge resolution, not a rewrite — and this assertion is what would have caught it had the two crossed the
    /// other way.
    @Test func `the wire discriminator is 84`() {
        let bytes = EditIntentCodec.encode(.setScoreInfo(writes: []))
        #expect(bytes[1] == 84)
        #expect(bytes.count < 128)
    }

    /// 79 is still 79 — appending above it is exactly the change that could have disturbed the case below.
    @Test func `appending above 79 left 79 where it was`() {
        let bytes = EditIntentCodec.encode(
            .setLyricVerse(
                text: .lyric(
                    anchor: VoiceElementID(
                        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                        measureIndex: 0, voiceIndex: 0, elementIndex: 0,
                    ),
                    verse: 0,
                ),
                toVerse: 1,
            ),
        )
        #expect(bytes[1] == 79)
    }

    /// A field byte outside the table is REFUSED rather than folded onto a default. A credit quietly dropped on
    /// the way in looks to the user exactly like the save not happening, which is the failure this whole intent
    /// exists to remove.
    @Test func `an unknown field byte is refused`() {
        var write = ScoreInfoWriteWire(from: ScoreInfoWrite(field: .title, text: "x"))
        write.field = 99
        let wire = EditIntentWire.setScoreInfo(SetScoreInfoIntentWire(writes: []))
        var payload = SetScoreInfoIntentWire(writes: [])
        payload.writes = [write]
        _ = wire
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setScoreInfo(payload).encodeToData())
        }
    }

    /// The field table's order IS the wire layout, so it is pinned here rather than left to `allCases`.
    @Test func `the field table's wire order is fixed`() throws {
        let expected: [(ScoreInfoWrite.Field, UInt8)] = [
            (.title, 0), (.subtitle, 1), (.composer, 2), (.arranger, 3), (.lyricist, 4), (.copyright, 5),
        ]
        for (field, byte) in expected {
            let wire = ScoreInfoWriteWire(from: ScoreInfoWrite(field: field, text: "x"))
            #expect(wire.field == byte, "\(field)")
            #expect(try wire.decoded().field == field)
        }
    }

    /// The committed bytes of `ScoreInfoWriteWire` for a write of each field, now that its field byte goes through the
    /// public `ScoreInfoFieldCode`: varint(length 7), tag 1 varint (`1 << 3 | 0` = 0x08) and the field code, tag 2
    /// varint (0x10) and `hasText` 1, tag 3 length-delimited (`3 << 3 | 2` = 0x1A), varint(length 1) and "x" (0x78).
    /// A reordered table, a reordered struct or a changed tag moves a byte here.
    @Test func `each written credit encodes to its committed bytes`() {
        let expected: [(ScoreInfoWrite.Field, [UInt8])] = [
            (.title, [0x07, 0x08, 0x00, 0x10, 0x01, 0x1A, 0x01, 0x78]),
            (.subtitle, [0x07, 0x08, 0x01, 0x10, 0x01, 0x1A, 0x01, 0x78]),
            (.composer, [0x07, 0x08, 0x02, 0x10, 0x01, 0x1A, 0x01, 0x78]),
            (.arranger, [0x07, 0x08, 0x03, 0x10, 0x01, 0x1A, 0x01, 0x78]),
            (.lyricist, [0x07, 0x08, 0x04, 0x10, 0x01, 0x1A, 0x01, 0x78]),
            (.copyright, [0x07, 0x08, 0x05, 0x10, 0x01, 0x1A, 0x01, 0x78]),
        ]
        for (field, bytes) in expected {
            let wire = ScoreInfoWriteWire(from: ScoreInfoWrite(field: field, text: "x"))
            #expect([UInt8](wire.encodeToData()) == bytes, "\(field)")
        }
    }

    /// A cleared credit still sends every field: `hasText` 0 and an empty text (varint length 0), so the body is 6.
    @Test func `a cleared credit encodes to its committed bytes`() {
        let wire = ScoreInfoWriteWire(from: ScoreInfoWrite(field: .composer, text: nil))
        #expect([UInt8](wire.encodeToData()) == [0x06, 0x08, 0x02, 0x10, 0x00, 0x1A, 0x00])
    }

    /// One past the table: the bytes decode as a struct, and `decoded()` refuses the field byte with the discriminator
    /// error rather than folding it onto a default.
    @Test func `a field byte of 6 is refused as an unknown discriminator`() throws {
        let wire = try ScoreInfoWriteWire(decoding: Data([0x07, 0x08, 0x06, 0x10, 0x01, 0x1A, 0x01, 0x78]))
        #expect(wire.field == 6)
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(6)) {
            try wire.decoded()
        }
    }
}
