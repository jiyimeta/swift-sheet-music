import Foundation
import SheetMusicCore
import SheetMusicEditWire
import Testing

/// Hand-derived bytes for the item identities whose wire shape changed or appeared with per-staff signature
/// identities and grace-note selection. `ScoreElementIDDecoderTest` on Android decodes these exact vectors, so the
/// Kotlin models that the generated codecs build are checked against Swift-side evidence rather than against their
/// own encoder.
///
/// Tags are (field << 3) | wireType, with 2 for nested messages and 0 for varints; Int32 values zig-zag to 2n and a
/// Bool is a plain varint. Staff payload = 4 bytes, voice-element payload = 12.
@Suite("ScoreItemID wire — signatures and grace notes")
struct ScoreItemIDSignatureAndGraceWireTests {
    private static let staff = StaffAddress(partIndex: 2, staffIndexInPart: 1)

    private static let cases: [(item: ScoreItemID, bytes: [UInt8])] = [
        // Element choice 5: measureIndex 7 (0x0E), staff tag 2 + length 4; element payload 9, outer payload 12.
        (
            .element(.keySignature(measureIndex: 7, staff: staff)),
            [0x0C, 0x05, 0x0A, 0x09, 0x05, 0x08, 0x0E, 0x12, 0x04, 0x08, 0x04, 0x10, 0x02],
        ),
        // Element choice 6, otherwise identical.
        (
            .element(.timeSignature(measureIndex: 7, staff: staff)),
            [0x0C, 0x05, 0x0A, 0x09, 0x06, 0x08, 0x0E, 0x12, 0x04, 0x08, 0x04, 0x10, 0x02],
        ),
        // Item choice 6: parent (length 12), isAfter 1, graceIndex 1 (0x02), noteIndexInGraceChord 2 (0x04);
        // grace payload 20, outer payload 23.
        (
            .graceNote(GraceNoteID(
                parent: VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 1, elementIndex: 4),
                side: .after, graceIndex: 1, noteIndexInGraceChord: 2,
            )),
            [
                0x17, 0x06, 0x0A, 0x14, 0x0A, 0x0C,
                0x0A, 0x04, 0x08, 0x04, 0x10, 0x02, 0x10, 0x06, 0x18, 0x02, 0x20, 0x08,
                0x10, 0x01, 0x18, 0x02, 0x20, 0x04,
            ],
        ),
    ]

    @Test("Signature and grace-note identities encode to the hand-derived bytes and decode back", arguments: 0 ..< 3)
    func handDerivedBytes(_ index: Int) throws {
        let (item, bytes) = Self.cases[index]
        #expect(ScoreItemIDCodec.encode(item) == Data(bytes))
        #expect(try ScoreItemIDCodec.decode(Data(bytes)) == item)
    }
}
