#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    struct MetronomeBeatCodecTests {
        // Byte-count and byte-sequence assertions are superseded by golden
        // fixtures in the Kotlin codec tests. Only round-trip tests are kept here.

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
    }
#endif
