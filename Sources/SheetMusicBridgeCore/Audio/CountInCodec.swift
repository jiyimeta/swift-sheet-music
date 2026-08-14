import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicFoundation
import Wirelet

/// Encodes the shared count-in schedule for the Android host. The wire types themselves live in
/// `Metadata/CountInWire.swift`, where the Kotlin codegen can see them.
public enum CountInCodec {
    public static func encode(_ value: CountInWire) -> Data {
        value.encodeToData()
    }

    /// Projects the shared tick-based schedule onto the wire, converting each tick to seconds at the
    /// start position's tempo. `division` is ticks-per-quarter, so `tick / division` is quarter notes and
    /// `× 60 / quarterBpm` turns that into seconds.
    ///
    /// A non-positive division or tempo yields an empty schedule rather than a division by zero — the
    /// host reads that as "no count-in" and starts immediately.
    public static func wire(from result: CountInBeats.Result, division: Int) -> CountInWire {
        guard division > 0, result.quarterBpm > 0 else {
            return CountInWire(totalSeconds: 0, preRollTicks: 0, beats: [])
        }
        let secondsPerTick = 60.0 / (result.quarterBpm * Double(division))
        return CountInWire(
            totalSeconds: Double(result.preRollTicks) * secondsPerTick,
            preRollTicks: Int32(clamping: result.preRollTicks),
            beats: result.beats.map {
                CountInBeatWire(
                    offsetSeconds: Double($0.tick) * secondsPerTick,
                    isDownbeat: $0.isDownbeat,
                )
            },
        )
    }
}
