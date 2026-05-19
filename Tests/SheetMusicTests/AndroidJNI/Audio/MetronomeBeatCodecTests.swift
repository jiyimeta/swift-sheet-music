#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    struct MetronomeBeatCodecTests {
        // MetronomeBeatArray blob:
        //   u16 version (= 1)
        //   i32 count
        //   count × { i64 tick; i32 kind; i32 _reserved }   16 bytes per entry
        //
        // kind mapping: 0=downbeat (isDownbeat=true), 1=upbeat (isDownbeat=false)

        @Test
        func emptyArrayRoundTrip() throws {
            let blob = MetronomeBeatCodec.encodeArray([])
            let decoded = try MetronomeBeatCodec.decodeArray(blob)
            #expect(decoded.isEmpty)
        }

        @Test
        func singleDownbeatRoundTrip() throws {
            let beat = MetronomeBeat(tick: 0, isDownbeat: true)
            let blob = MetronomeBeatCodec.encodeArray([beat])
            let decoded = try MetronomeBeatCodec.decodeArray(blob)
            #expect(decoded.count == 1)
            #expect(decoded[0].tick == 0)
            #expect(decoded[0].isDownbeat == true)
        }

        @Test
        func singleUpbeatRoundTrip() throws {
            let beat = MetronomeBeat(tick: 480, isDownbeat: false)
            let blob = MetronomeBeatCodec.encodeArray([beat])
            let decoded = try MetronomeBeatCodec.decodeArray(blob)
            #expect(decoded.count == 1)
            #expect(decoded[0].tick == 480)
            #expect(decoded[0].isDownbeat == false)
        }

        @Test
        func multipleBeatsRoundTrip() throws {
            let beats = [
                MetronomeBeat(tick: 0, isDownbeat: true),
                MetronomeBeat(tick: 480, isDownbeat: false),
                MetronomeBeat(tick: 960, isDownbeat: false),
                MetronomeBeat(tick: 1440, isDownbeat: false),
                MetronomeBeat(tick: 1920, isDownbeat: true),
            ]
            let blob = MetronomeBeatCodec.encodeArray(beats)
            let decoded = try MetronomeBeatCodec.decodeArray(blob)
            #expect(decoded == beats)
        }

        @Test
        func entrySize16Bytes() {
            // 2 (version) + 4 (count) + 1 * 16 (entry) = 22 bytes for a single entry
            let beat = MetronomeBeat(tick: 0, isDownbeat: true)
            let blob = MetronomeBeatCodec.encodeArray([beat])
            #expect(blob.count == 22)
        }

        @Test
        func knownBytesDownbeat() {
            // tick=1, downbeat=true → kind=0
            // [1,0] version, [1,0,0,0] count=1
            // tick=1 as i64: [1,0,0,0,0,0,0,0]
            // kind=0: [0,0,0,0]
            // reserved: [0,0,0,0]
            let beat = MetronomeBeat(tick: 1, isDownbeat: true)
            let blob = MetronomeBeatCodec.encodeArray([beat])
            let expected = Data([
                0x01, 0x00, // version=1
                0x01, 0x00, 0x00, 0x00, // count=1
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // tick=1
                0x00, 0x00, 0x00, 0x00, // kind=0 (downbeat)
                0x00, 0x00, 0x00, 0x00, // _reserved
            ])
            #expect(blob == expected)
        }

        @Test
        func knownBytesUpbeat() {
            // tick=480, upbeat=false → kind=1
            let beat = MetronomeBeat(tick: 480, isDownbeat: false)
            let blob = MetronomeBeatCodec.encodeArray([beat])
            // Verify kind byte at offset 12 (2 version + 4 count + 8 tick offset = 14... actually 6+8=14)
            // blob[14] = kind LSB
            #expect(blob[14] == 0x01) // kind=1=upbeat
        }

        @Test
        func versionMismatch() {
            var blob = MetronomeBeatCodec.encodeArray([])
            blob[0] = 0xFF // corrupt version
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try MetronomeBeatCodec.decodeArray(blob)
            }
        }
    }
#endif
