#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct ClefAnchorCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 1)

        // Wire format for ClefAnchorPayload:
        //   u8 kind   (0=explicit, 1=staffDefault)
        //   if kind==0: VoiceElementIDPayload (20 bytes) → total 21 bytes
        //   if kind==1: StaffAddress (8 bytes)           → total 9 bytes

        @Test
        func explicitClefPayloadIs21Bytes() {
            let id = VoiceElementID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
            )
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(.explicit(id), into: &w)
            #expect(w.data.count == 21)
        }

        @Test
        func staffDefaultClefPayloadIs9Bytes() {
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(.staffDefault(addr), into: &w)
            #expect(w.data.count == 9)
        }

        @Test
        func explicitKnownFirstByte() {
            let id = VoiceElementID(
                staff: addr,
                measureIndex: 1,
                voiceIndex: 0,
                elementIndex: 2,
            )
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(.explicit(id), into: &w)
            #expect(w.data[0] == 0x00) // kind=explicit
        }

        @Test
        func staffDefaultKnownFirstByte() {
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(.staffDefault(addr), into: &w)
            #expect(w.data[0] == 0x01) // kind=staffDefault
        }

        @Test
        func explicitRoundTrip() throws {
            let id = VoiceElementID(
                staff: addr,
                measureIndex: 3,
                voiceIndex: 1,
                elementIndex: 7,
            )
            let original = ClefAnchor.explicit(id)
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ClefAnchorCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func staffDefaultRoundTrip() throws {
            let original = ClefAnchor.staffDefault(addr)
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ClefAnchorCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func unknownKindThrows() {
            // kind byte = 0xFF is not a valid case
            var r = AudioBinaryReader(Data([0xFF]))
            #expect(throws: Error.self) {
                _ = try ClefAnchorCodec.decodePayload(&r)
            }
        }

        @Test
        func explicitKnownBytes() {
            // kind=0, partIndex=0, staffIndexInPart=1, measureIndex=0, voiceIndex=0, elementIndex=0
            let id = VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
            )
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(.explicit(id), into: &w)
            let expected = Data([
                0x00, // kind=explicit
                0x00, 0x00, 0x00, 0x00, // partIndex=0
                0x01, 0x00, 0x00, 0x00, // staffIndexInPart=1
                0x00, 0x00, 0x00, 0x00, // measureIndex=0
                0x00, 0x00, 0x00, 0x00, // voiceIndex=0
                0x00, 0x00, 0x00, 0x00, // elementIndex=0
            ])
            #expect(w.data == expected)
        }

        @Test
        func staffDefaultKnownBytes() {
            // kind=1, partIndex=2, staffIndexInPart=0
            let a = StaffAddress(partIndex: 2, staffIndexInPart: 0)
            var w = AudioBinaryWriter()
            ClefAnchorCodec.encodePayload(.staffDefault(a), into: &w)
            let expected = Data([
                0x01, // kind=staffDefault
                0x02, 0x00, 0x00, 0x00, // partIndex=2
                0x00, 0x00, 0x00, 0x00, // staffIndexInPart=0
            ])
            #expect(w.data == expected)
        }
    }
#endif
