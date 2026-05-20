#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct ScoreItemIDCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // ScoreItemIDPayload:
        //   u8 kind  0=note, 1=rest, 2=tuplet, 3=clef
        //   case 0: NoteIDPayload (24 bytes)
        //   case 1: RestIDPayload (20 bytes)
        //   case 2: TupletIDPayload (20 bytes)
        //   case 3: ClefAnchorPayload (variable)

        // MARK: - Payload size

        @Test
        func notePayloadIs25Bytes() {
            let id = ScoreItemID.note(NoteID(
                staff: addr, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data.count == 25) // 1 kind + 24 note
        }

        @Test
        func restPayloadIs21Bytes() {
            let id = ScoreItemID.rest(RestID(
                staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data.count == 21) // 1 kind + 20 rest
        }

        @Test
        func tupletPayloadIs21Bytes() {
            let id = ScoreItemID.tuplet(TupletID(
                staff: addr, measureIndex: 0, voiceIndex: 0, startElementIndex: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data.count == 21) // 1 kind + 20 tuplet
        }

        @Test
        func clefExplicitPayloadIs22Bytes() {
            let veid = VoiceElementID(
                staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            )
            let id = ScoreItemID.clef(.explicit(veid))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data.count == 22) // 1 kind + 21 clefAnchor(explicit)
        }

        @Test
        func clefStaffDefaultPayloadIs10Bytes() {
            let id = ScoreItemID.clef(.staffDefault(addr))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data.count == 10) // 1 kind + 9 clefAnchor(staffDefault)
        }

        // MARK: - Kind discriminator

        @Test
        func noteKindByteIsZero() {
            let id = ScoreItemID.note(NoteID(
                staff: addr, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data[0] == 0x00)
        }

        @Test
        func restKindByteIsOne() {
            let id = ScoreItemID.rest(RestID(
                staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data[0] == 0x01)
        }

        @Test
        func tupletKindByteIsTwo() {
            let id = ScoreItemID.tuplet(TupletID(
                staff: addr, measureIndex: 0, voiceIndex: 0, startElementIndex: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data[0] == 0x02)
        }

        @Test
        func clefKindByteIsThree() {
            let id = ScoreItemID.clef(.staffDefault(addr))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(id, into: &w)
            #expect(w.data[0] == 0x03)
        }

        // MARK: - Round-trip payload

        @Test
        func noteRoundTrip() throws {
            let original = ScoreItemID.note(NoteID(
                staff: addr, measureIndex: 5, voiceIndex: 0,
                elementIndex: 3, noteIndexInChord: 1,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreItemIDCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func restRoundTrip() throws {
            let original = ScoreItemID.rest(RestID(
                staff: addr, measureIndex: 2, voiceIndex: 1, elementIndex: 0,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreItemIDCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func tupletRoundTrip() throws {
            let original = ScoreItemID.tuplet(TupletID(
                staff: addr, measureIndex: 1, voiceIndex: 0, startElementIndex: 4,
            ))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreItemIDCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func clefExplicitRoundTrip() throws {
            let veid = VoiceElementID(
                staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 2,
            )
            let original = ScoreItemID.clef(.explicit(veid))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreItemIDCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func clefStaffDefaultRoundTrip() throws {
            let original = ScoreItemID.clef(.staffDefault(addr))
            var w = AudioBinaryWriter()
            ScoreItemIDCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreItemIDCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        // MARK: - Top-level blob

        @Test
        func topLevelNoteRoundTrip() throws {
            let original = ScoreItemID.note(NoteID(
                staff: addr, measureIndex: 3, voiceIndex: 0,
                elementIndex: 1, noteIndexInChord: 0,
            ))
            let blob = ScoreItemIDCodec.encode(original)
            let decoded = try ScoreItemIDCodec.decode(blob)
            #expect(decoded == original)
        }

        @Test
        func topLevelVersionMismatch() {
            let id = ScoreItemID.rest(RestID(
                staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            ))
            var blob = ScoreItemIDCodec.encode(id)
            blob[1] = 0xFF // corrupt version MSB
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try ScoreItemIDCodec.decode(blob)
            }
        }

        // MARK: - Array blob

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
#endif
