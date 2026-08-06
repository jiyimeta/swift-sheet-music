#if !os(Android)
    import Foundation
    import SheetMusicCore
    import SheetMusicEditWire
    import Testing
    import Wirelet

    struct ScoreItemIDCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // Byte-count, discriminator-offset, and byte-sequence assertions are
        // superseded by golden fixtures in the Kotlin codec tests. Only
        // round-trip tests are kept here.

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
#endif
