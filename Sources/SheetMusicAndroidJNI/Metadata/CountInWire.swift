import Foundation
import Wirelet

/// One count-in click, already resolved to **seconds** from the start of the pre-roll.
///
/// The shared `CountInBeats` works in ticks, but a host would then have to redo the tick→seconds
/// conversion (`tick / division × 60 / quarterBpm`) to schedule the clicks — tempo math is exactly the
/// kind of thing that must not be re-derived per platform. `CountInCodec.wire(from:division:)` converts
/// here, so the Android engine only has to wait out the offsets.
@WireFormat
public struct CountInBeatWire {
    public var offsetSeconds: Double
    public var isDownbeat: Bool
}

/// A resolved count-in schedule: the clicks plus how long the whole pre-roll lasts.
///
/// `totalSeconds` is NOT simply the last beat's offset — the pre-roll runs to the END of its final beat,
/// and an anacrusis or a mid-measure start stretches the region further, so a host must wait
/// `totalSeconds` before starting the score rather than stopping at the last click.
///
/// Empty `beats` with `totalSeconds == 0` means "no count-in for this position" (an unparseable score, a
/// zero tempo): the host starts playback immediately, exactly as if the setting were off.
@WireFormat
public struct CountInWire {
    public var totalSeconds: Double
    /// The same region measured in MIDI ticks — where the music starts inside the count-in's own
    /// sequence. The Android engine plays the pre-roll off a `fluid_player` and hands over to the score
    /// when that player's tick reaches this, so the clicks are placed by the audio clock rather than by
    /// a wall-clock wait (which quantized every click to whichever output buffer happened to pick the
    /// note up, and wobbled audibly).
    public var preRollTicks: Int32
    public var beats: [CountInBeatWire]
}
