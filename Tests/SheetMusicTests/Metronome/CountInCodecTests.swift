import SheetMusicAudioCore
@testable import SheetMusicBridgeCore
import Testing

/// The count-in schedule the Android host is handed: `CountInWire.totalSeconds` and the beat offsets have to be the
/// pre-roll the count sequence plays, which is seeded with the start's tempo rounded to a whole BPM.
struct CountInCodecTests {
    @Test func theWireCarriesTheSequencePreRoll() {
        let result = CountInBeats.Result(
            preRollTicks: 1920,
            beats: [MetronomeBeat(tick: 0, isDownbeat: true), MetronomeBeat(tick: 480, isDownbeat: false)],
            quarterBpm: 92.5,
        )
        let wire = CountInCodec.wire(from: result, division: 480)
        #expect(abs(wire.totalSeconds - 2.580644) < 1e-9)
        #expect(abs(wire.beats[1].offsetSeconds - 0.645161) < 1e-9)
        #expect(wire.preRollTicks == 1920)
    }
}
