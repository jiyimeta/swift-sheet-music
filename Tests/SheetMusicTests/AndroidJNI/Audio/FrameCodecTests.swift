#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    struct FrameCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // Frame top-level blob:
        //   u16 version (= 1)
        //   i64 tick
        //   i64 timeSecondsMicros  (round(timeSeconds * 1e6) as Int64)
        //   ScoreCursorPayload     (inline, no inner version)

        @Test
        func beatFrameRoundTrip() throws {
            let original = PlaybackTimeline.Frame(
                tick: 480,
                timeSeconds: 0.5,
                cursor: .beat(measureIndex: 0, tickInMeasure: 480),
            )
            let blob = FrameCodec.encode(original)
            let decoded = try FrameCodec.decode(blob)
            #expect(decoded.tick == original.tick)
            #expect(abs(decoded.timeSeconds - original.timeSeconds) < 1e-5)
            #expect(decoded.cursor == original.cursor)
        }

        @Test
        func itemFrameRoundTrip() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 2, voiceIndex: 0,
                elementIndex: 1, noteIndexInChord: 0,
            )
            let original = PlaybackTimeline.Frame(
                tick: 960,
                timeSeconds: 1.0,
                cursor: .item(.note(noteID)),
            )
            let blob = FrameCodec.encode(original)
            let decoded = try FrameCodec.decode(blob)
            #expect(decoded.tick == original.tick)
            #expect(abs(decoded.timeSeconds - original.timeSeconds) < 1e-5)
            #expect(decoded.cursor == original.cursor)
        }

        @Test
        func versionMismatch() {
            let frame = PlaybackTimeline.Frame(
                tick: 0, timeSeconds: 0.0,
                cursor: .beat(measureIndex: 0, tickInMeasure: 0),
            )
            var blob = FrameCodec.encode(frame)
            blob[0] = 0xFF // corrupt version
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try FrameCodec.decode(blob)
            }
        }

        @Test
        func timeSecondsMicrosRoundTrip() throws {
            // 1.23456789 seconds → micros = 1_234_568 (rounded)
            let original = PlaybackTimeline.Frame(
                tick: 100, timeSeconds: 1.23456789,
                cursor: .beat(measureIndex: 0, tickInMeasure: 0),
            )
            let blob = FrameCodec.encode(original)
            let decoded = try FrameCodec.decode(blob)
            // Within 1 microsecond
            #expect(abs(decoded.timeSeconds - original.timeSeconds) < 1e-5)
        }

        @Test
        func knownBytesVersionAndTick() {
            // tick=1, timeSeconds=0 → micros=0, cursor=beat(0,0)
            let frame = PlaybackTimeline.Frame(
                tick: 1, timeSeconds: 0.0,
                cursor: .beat(measureIndex: 0, tickInMeasure: 0),
            )
            let blob = FrameCodec.encode(frame)
            // First 2 bytes: version=1 LE
            #expect(blob[0] == 0x01)
            #expect(blob[1] == 0x00)
            // Next 8 bytes: tick=1 as i64 LE
            #expect(blob[2] == 0x01)
            #expect(blob[3] == 0x00)
            // Remaining zeroes for tick high bytes
            #expect(blob[4] == 0x00)
        }
    }
#endif
