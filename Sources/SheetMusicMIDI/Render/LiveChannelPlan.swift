import Foundation
import SheetMusicCore

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
/// Dedup is **within-part only**: collapsing across parts would destroy
/// per-part mixer independence.
public struct LiveChannelPlan: Sendable, Equatable {
    /// One deduped (part × instrument) pair — one mixer strip, one live
    /// MIDI channel.
    public struct Strip: Sendable, Equatable {
        public let partIndex: Int
        /// Index into the part's DEDUPED instruments in first-appearance
        /// order. Stable for a given score, and the `ordinal` of
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
    /// Timeline index → deduped ordinal, per part. Lets a caller that
    /// knows "the 3rd change in part 1" find the strip it merged into.
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

    public func dedupedOrdinal(partIndex: Int, timelineIndex: Int) -> Int? {
        guard ordinalByTimelineIndex.indices.contains(partIndex),
              ordinalByTimelineIndex[partIndex].indices.contains(timelineIndex)
        else { return nil }
        return ordinalByTimelineIndex[partIndex][timelineIndex]
    }

    public static func build(score: Score) -> LiveChannelPlan {
        let assignments = MidiRenderer.assignChannels(score: score)
        var strips: [Strip] = []
        var remap: [MidiChannelKey: Int] = [:]
        var ordinalByTimelineIndex: [[Int]] = []
        var nextMelodic = 0
        func takeLiveChannel() -> Int {
            let channel = MidiRenderer.melodicChannels[
                nextMelodic % MidiRenderer.melodicChannels.count,
            ]
            nextMelodic += 1
            return channel
        }

        for partIndex in score.parts.indices {
            let timeline = score.instrumentTimeline(forPart: partIndex)
            let partAssignments = assignments.indices.contains(partIndex)
                ? assignments[partIndex] : []
            // Dedup key: the primary flavour's SOUNDING fields only
            // (program, bank, volume, pan, reverb, chorus) — `name`,
            // `midiChannel`, and `midiPort` are identity/routing
            // metadata from the rendered SMF, not part of what makes
            // two instances sound alike. `InstrumentChannel`'s
            // synthesized `Hashable` covers every stored field, so a
            // literal per-instance value (declared channel included)
            // would never collapse two instances MuseScore gave
            // different channel numbers to — exactly the case this
            // dedup exists to catch. Zeroing those three fields before
            // hashing keeps `InstrumentChannel`'s own conformance
            // untouched (still safe to hand off to a dictionary
            // elsewhere) while keying this dictionary on sound alone.
            var ordinalForFlavour: [InstrumentChannel: Int] = [:]
            var ordinals: [Int] = []
            for (timelineIndex, point) in timeline.enumerated() {
                var flavour = point.instrument.channel
                flavour.name = nil
                flavour.midiChannel = nil
                flavour.midiPort = nil
                let ordinal: Int
                if let existing = ordinalForFlavour[flavour] {
                    ordinal = existing
                } else {
                    ordinal = strips.count(where: { $0.partIndex == partIndex })
                    ordinalForFlavour[flavour] = ordinal
                    let liveChannel = point.instrument.useDrumset
                        ? MidiRenderer.drumChannel
                        : takeLiveChannel()
                    strips.append(Strip(
                        partIndex: partIndex,
                        ordinal: ordinal,
                        instrument: point.instrument,
                        liveChannel: liveChannel,
                    ))
                }
                ordinals.append(ordinal)
                // Every rendered assignment for this timeline index —
                // all its `<Channel>` flavours — remaps onto the strip.
                let liveChannel = strips.last(where: {
                    $0.partIndex == partIndex && $0.ordinal == ordinal
                })?.liveChannel ?? 0
                for assignment in partAssignments
                    where assignment.instrumentOrdinal == timelineIndex
                {
                    remap[assignment.key] = liveChannel
                }
            }
            ordinalByTimelineIndex.append(ordinals)
        }
        return LiveChannelPlan(
            strips: strips,
            remap: remap,
            ordinalByTimelineIndex: ordinalByTimelineIndex,
        )
    }
}
