import SheetMusicCore
import SheetMusicFoundation

/// The single-port channel layout used for LIVE playback.
///
/// The rendered SMF is MuseScore-exact: one channel per instrument-change
/// instance, spread across as many MIDI ports as the source declared.
/// A live synth has one port and 16 channels, so this plan collapses
/// them — but only where the collapse is inaudible.
///
/// **Dedup rule.** Within a part, two instruments collapse onto one live
/// channel iff their primary `InstrumentChannel`s are equal on the six
/// SOUNDING fields: `program`, `bank`, `volume`, `pan`, `reverb`,
/// `chorus`. Three fields are deliberately EXCLUDED from the key:
///
/// - `name` — a MuseScore mixer UI label ("normal", "pizzicato") with
///   no audible effect.
/// - `midiChannel` / `midiPort` — the rendered SMF's routing address.
///   MuseScore allocates a FRESH channel for every change instance, so
///   two instances of one instrument differ here BY DESIGN; keying on
///   them would collapse nothing, which is the whole premise of this
///   pass.
///
/// Keying on sound alone makes merged instances audibly identical by
/// construction, and an instance the author tweaked in MuseScore's
/// mixer keeps its own channel because a sounding field differs.
///
/// The instruments are the part's SOUND timeline: a play technique's
/// variant ("Violin (Pizzicato)") is another instrument whose primary
/// channel differs in program, so it earns a strip of its own — after
/// every part's instruments have theirs, and only while a melodic live
/// channel is left (`LiveChannelPlan.Builder`).
///
/// Dedup is **within-part only**: collapsing across parts would destroy
/// per-part mixer independence.
public struct LiveChannelPlan: Sendable, Equatable {
    /// One deduped (part × instrument) pair — one mixer strip, one live
    /// MIDI channel.
    public struct Strip: Sendable, Equatable {
        public let partIndex: Int
        /// Index into the part's DEDUPED instruments in first-appearance
        /// order, its play techniques' sounds after them. Stable for a
        /// given score — adding a technique never renumbers an
        /// instrument — and the `ordinal` of
        /// `MixerChannel.Kind.instrument(partIndex:ordinal:)`.
        public let ordinal: Int
        public let instrument: Instrument
        public let liveChannel: Int

        public init(
            partIndex: Int, ordinal: Int,
            instrument: Instrument, liveChannel: Int,
        ) {
            self.partIndex = partIndex
            self.ordinal = ordinal
            self.instrument = instrument
            self.liveChannel = liveChannel
        }
    }

    public let strips: [Strip]
    /// Rendered `(port, channel)` → live single-port channel.
    public let remap: [MidiChannelKey: Int]
    /// Sound-timeline index → deduped ordinal, per part. Lets a caller that
    /// knows "the 3rd point of part 1's sound timeline" find the strip it
    /// merged into.
    private let ordinalByTimelineIndex: [[Int]]

    /// Memberwise init at `internal` access. The synthesized memberwise
    /// init would be `private` (matching `ordinalByTimelineIndex`'s
    /// access), which `@testable import` cannot reach across files —
    /// Task 10's tests construct a `LiveChannelPlan` directly.
    init(
        strips: [Strip],
        remap: [MidiChannelKey: Int],
        ordinalByTimelineIndex: [[Int]],
    ) {
        self.strips = strips
        self.remap = remap
        self.ordinalByTimelineIndex = ordinalByTimelineIndex
    }

    /// Channels the live mixer owns — passed to `MidiSynthPostProcess`
    /// so their tick-0 program / CC 7 is stripped and the mixer stays
    /// the sole authority.
    public var managedChannels: Set<Int> {
        Set(strips.map(\.liveChannel))
    }

    public func strip(partIndex: Int, ordinal: Int) -> Strip? {
        strips.first { $0.partIndex == partIndex && $0.ordinal == ordinal }
    }

    /// The strip ordinal of point `timelineIndex` of the part's SOUND timeline (`Score.soundTimeline(forPart:)`): its
    /// instrument points and its play techniques' sounds. With no technique that is the instrument timeline, index for
    /// index; with one, an `instrumentTimeline(forPart:)` index no longer names the same point.
    public func dedupedOrdinal(partIndex: Int, timelineIndex: Int) -> Int? {
        guard ordinalByTimelineIndex.indices.contains(partIndex),
              ordinalByTimelineIndex[partIndex].indices.contains(timelineIndex)
        else { return nil }
        return ordinalByTimelineIndex[partIndex][timelineIndex]
    }

    public static func build(score: Score) -> LiveChannelPlan {
        var builder = Builder(score: score)
        for partIndex in score.parts.indices {
            builder.addInstruments(ofPart: partIndex)
        }
        for partIndex in score.parts.indices {
            builder.addTechniques(ofPart: partIndex)
        }
        return builder.plan
    }
}
