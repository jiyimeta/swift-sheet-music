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
    @Test func `the wire discriminator is 80`() {
        let bytes = EditIntentCodec.encode(.setScoreInfo(writes: []))
        #expect(bytes[1] == 80)
        #expect(bytes.count < 128)
    }

    /// 79 is still 79 — appending 80 is exactly the change that could have disturbed the case below it.
    @Test func `appending 80 left 79 where it was`() {
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
}
