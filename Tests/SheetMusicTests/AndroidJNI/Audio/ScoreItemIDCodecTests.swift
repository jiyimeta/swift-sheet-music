import Foundation
import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

struct ScoreItemIDCodecTests {
    private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    // Existing round trips complement the append-only TLV discriminator checks below.
    // New identity byte expectations are hand-derived, not recorded from this encoder.

    @Test
    func noteRoundTrip() throws {
        let original = ScoreItemID.note(NoteID(
            staff: addr, measureIndex: 5, voiceIndex: 0,
            elementIndex: 3, noteIndexInChord: 1,
        ))
        let decoded = try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func restRoundTrip() throws {
        let original = ScoreItemID.rest(RestID(
            staff: addr, measureIndex: 2, voiceIndex: 1, elementIndex: 0,
        ))
        let decoded = try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func tupletRoundTrip() throws {
        let original = ScoreItemID.tuplet(TupletID(
            staff: addr, measureIndex: 1, voiceIndex: 0, startElementIndex: 4,
        ))
        let decoded = try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func clefExplicitRoundTrip() throws {
        let veid = VoiceElementID(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        )
        let original = ScoreItemID.clef(.explicit(veid))
        let decoded = try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func clefStaffDefaultRoundTrip() throws {
        let original = ScoreItemID.clef(.staffDefault(addr))
        let decoded = try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func emptyArrayRoundTrip() throws {
        let blob = ScoreItemIDCodec.encodeArray([])
        let decoded = try ScoreItemIDCodec.decodeArray(blob)
        #expect(decoded.isEmpty)
    }

    @Test
    func arrayRoundTrip() throws {
        let items: [ScoreItemID] = [
            .note(NoteID(staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)),
            .rest(RestID(staff: addr, measureIndex: 1, voiceIndex: 0, elementIndex: 2)),
            .clef(.staffDefault(addr)),
        ]
        let blob = ScoreItemIDCodec.encodeArray(items)
        let decoded = try ScoreItemIDCodec.decodeArray(blob)
        #expect(decoded == items)
    }
}

extension ScoreItemIDCodecTests {
    private static let start = NoteID(
        staff: StaffAddress(partIndex: 2, staffIndexInPart: 1),
        measureIndex: 3, voiceIndex: 1, elementIndex: 4, noteIndexInChord: 2,
    )
    private static let end = NoteID(
        staff: StaffAddress(partIndex: 3, staffIndexInPart: 2),
        measureIndex: 5, voiceIndex: 2, elementIndex: 6, noteIndexInChord: 3,
    )
    private static let newElements: [ScoreElementID] = [
        .tie(start: start, end: end),
        .slur(.chord(anchor: VoiceElementID(start), ordinal: 1)),
        .slur(.voice(VoiceElementID(start))),
        .jump(staff: start.staff, measureIndex: 7, index: 2),
        .marker(staff: start.staff, measureIndex: 7, index: 2),
    ]

    /// Tags are (field << 3) | wireType, with 2 for nested messages and 0 for Int32.
    /// Positive Int32 values zig-zag to 2*n. Staff payload = 4 bytes, anchor = 12, note = 14.
    /// Choice payloads include their discriminator and tagged values; each gets its own length prefix.
    private static let newElementBytes: [[UInt8]] = [
        // Tie: inner length 33 (0x21), outer length 36 (0x24).
        [
            0x24, 0x05, 0x0A, 0x21, 0x09,
            0x0A, 0x0E, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08, 0x28, 0x04,
            0x12, 0x0E, 0x0A, 0x04, 0x08, 0x06, 0x10, 0x04, 0x10, 0x0A, 0x18, 0x04, 0x20, 0x0C, 0x28, 0x06,
        ],
        // Chord slur: SlurID payload 17, element payload 20, outer payload 23.
        [
            0x17, 0x05, 0x0A, 0x14, 0x0A, 0x0A, 0x11, 0x00, 0x0A, 0x0C,
            0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08, 0x10, 0x02,
        ],
        // Voice slur: SlurID payload 15, element payload 18, outer payload 21.
        [
            0x15, 0x05, 0x0A, 0x12, 0x0A, 0x0A, 0x0F, 0x01, 0x0A, 0x0C,
            0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08,
        ],
        // Navigation: element payload 11, outer payload 14.
        [0x0E, 0x05, 0x0A, 0x0B, 0x0B, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x0E, 0x18, 0x04],
        [0x0E, 0x05, 0x0A, 0x0B, 0x0C, 0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x0E, 0x18, 0x04],
    ]

    @Test(
        "New element wire payloads preserve every nonzero field and match hand-derived bytes",
        arguments: 0 ..< 5,
    )
    func newElementWirePayloads(_ index: Int) throws {
        let item = ScoreItemID.element(Self.newElements[index])
        let bytes = Data(Self.newElementBytes[index])
        #expect(ScoreItemIDCodec.encode(item) == bytes)
        #expect(try ScoreItemIDCodec.decode(bytes) == item)
        #expect(try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(item)) == item)
        #expect(try ScoreItemIDCodec.decodeArray(ScoreItemIDCodec.encodeArray([item])) == [item])
    }

    /// Open a length-delimited choice and read its declaration-order discriminator.
    private static func choice(_ reader: inout WireFormatReader) throws -> (UInt64, WireFormatReader) {
        let length = try Int(reader.readVarint())
        var payload = try WireFormatReader(data: reader.readBytes(count: length))
        let discriminator = try payload.readVarint()
        return (discriminator, payload)
    }

    /// The enclosing choice's first associated value is TLV field 1, not a bare nested length.
    private static func nestedChoice(_ reader: inout WireFormatReader) throws -> (UInt64, WireFormatReader) {
        let field = try reader.readTag()
        #expect(field.tag == 1)
        #expect(field.wireType == .lengthDelimited)
        return try choice(&reader)
    }

    @Test("Element choices append at 9 through 12 and slur forms remain 0 and 1")
    func elementWireDiscriminators() throws {
        let anchor = VoiceElementID(Self.start)
        let old: [ScoreElementID] = [
            .dynamic(anchor: anchor), .fermata(anchor: anchor), .breath(anchor: anchor),
            .tempo(anchor: anchor), .spanner(anchor: anchor, kind: .pedal),
            .keySignature(measureIndex: 3), .timeSignature(measureIndex: 3),
            .barLine(measureIndex: 3, role: .explicit), .articulation(anchor: anchor, kind: .accent),
        ]
        let expected: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 12]
        for (id, ordinal) in zip(old + Self.newElements, expected) {
            var reader = WireFormatReader(data: ScoreItemIDCodec.encode(.element(id)))
            let (outer, outerPayload) = try Self.choice(&reader)
            var payload = outerPayload
            #expect(outer == 5)
            #expect(reader.isAtEnd)
            let (element, elementFields) = try Self.nestedChoice(&payload)
            var fields = elementFields
            #expect(element == ordinal)
            #expect(payload.isAtEnd)
            if case let .slur(slur) = id {
                let (form, _) = try Self.nestedChoice(&fields)
                switch slur {
                case .chord: #expect(form == 0)
                case .voice: #expect(form == 1)
                }
            }
        }
    }

    @Test("Outer item choices retain 0 through 5")
    func outerWireDiscriminators() throws {
        let items: [ScoreItemID] = [
            .note(Self.start),
            .rest(RestID(staff: Self.start.staff, measureIndex: 3, voiceIndex: 1, elementIndex: 4)),
            .tuplet(TupletID(staff: Self.start.staff, measureIndex: 3, voiceIndex: 1, startElementIndex: 4)),
            .clef(.explicit(VoiceElementID(Self.start))),
            .text(.harmony(anchor: VoiceElementID(Self.start))),
            .element(Self.newElements[0]),
        ]
        for (ordinal, item) in items.enumerated() {
            var reader = WireFormatReader(data: ScoreItemIDCodec.encode(item))
            let (discriminator, _) = try Self.choice(&reader)
            #expect(discriminator == UInt64(ordinal))
            #expect(reader.isAtEnd)
        }
    }
}
