import SheetMusicCore
import SheetMusicFoundation

extension LiveChannelPlan {
    /// Builds the plan in two passes: every part's instruments first, then every part's play techniques. An
    /// instrument's strip and live channel are therefore the ones it had before techniques sounded, and a
    /// technique's sound takes a strip only while a melodic channel is left — past that it plays on its instrument's
    /// strip, as the rendered SMF plays it on its instrument's channel (`MidiRenderer.assignChannels`).
    ///
    /// On one port the SMF runs out no later: its instruments share one round-robin of 15 counted per `<Channel>`, the
    /// live synth's 15 are counted per strip. A technique takes an SMF channel free on its own port, though, so a score
    /// whose instruments declare a second `<midiPort>` (or pin `<midiChannel>`s) can leave a technique a channel in the
    /// exported file once the live synth is full — and then it sounds as its instrument live, as an instrument past the
    /// fifteenth already shares a live channel there.
    struct Builder {
        private let timelines: [[Score.SoundPoint]]
        private let assignments: [[MidiRenderer.ChannelAssignment]]
        private var strips: [Strip] = []
        private var remap: [MidiChannelKey: Int] = [:]
        /// Per part, per timeline index: the strip ordinal it plays on, once placed.
        private var ordinals: [[Int?]]
        private var ordinalForSound: [[InstrumentChannel: Int]]
        private var nextMelodic = 0

        init(score: Score) {
            assignments = MidiRenderer.assignChannels(score: score)
            timelines = score.parts.indices.map { score.soundTimeline(forPart: $0) }
            ordinals = timelines.map { Array(repeating: nil, count: $0.count) }
            ordinalForSound = Array(repeating: [:], count: timelines.count)
        }

        var plan: LiveChannelPlan {
            // Every point is placed: an instrument point in the first pass, a technique after its base point.
            assert(ordinals.allSatisfy { !$0.contains(nil) }, "a sound-timeline point was left without a strip")
            return LiveChannelPlan(
                strips: strips.sorted { ($0.partIndex, $0.ordinal) < ($1.partIndex, $1.ordinal) },
                remap: remap,
                ordinalByTimelineIndex: ordinals.map { $0.map { $0 ?? 0 } },
            )
        }

        /// The seed and every instrument change of a part.
        mutating func addInstruments(ofPart partIndex: Int) {
            for (index, point) in timelines[partIndex].enumerated() where point.basePoint == nil {
                let key = Self.soundKey(point.instrument)
                let ordinal = ordinalForSound[partIndex][key] ?? newStrip(partIndex, point.instrument, key: key)
                place(index, ordinal: ordinal, partIndex: partIndex)
            }
        }

        /// The part's play techniques. A technique that sounds like an earlier point plays on that point's strip;
        /// one with no sound of its own in the rendered SMF — its General MIDI sound found no free channel — or with
        /// no live channel left plays on its instrument's.
        mutating func addTechniques(ofPart partIndex: Int) {
            let partAssignments = assignments.indices.contains(partIndex) ? assignments[partIndex] : []
            for (index, point) in timelines[partIndex].enumerated() {
                guard let base = point.basePoint, let baseOrdinal = ordinals[partIndex][base] else { continue }
                let ordinal: Int
                let key = Self.soundKey(point.instrument)
                let rendered = point.flavourSource != nil
                    || partAssignments.contains { $0.instrumentOrdinal == index }
                if let earlier = point.reusesPoint {
                    ordinal = ordinals[partIndex][earlier] ?? baseOrdinal
                } else if !rendered {
                    ordinal = baseOrdinal
                } else if let existing = ordinalForSound[partIndex][key] {
                    ordinal = existing
                } else if nextMelodic < MidiRenderer.melodicChannels.count {
                    ordinal = newStrip(partIndex, point.instrument, key: key)
                } else {
                    ordinal = baseOrdinal
                }
                let liveChannel = place(index, ordinal: ordinal, partIndex: partIndex)
                // A technique sounding through one of the instrument's own `<Channel>`s owns that channel's notes.
                if let source = point.flavourSource {
                    let flavours = partAssignments.filter { $0.instrumentOrdinal == source.point }
                    if flavours.indices.contains(source.flavour) {
                        remap[flavours[source.flavour].key] = liveChannel
                    }
                }
            }
        }

        /// Dedup key: the primary flavour's SOUNDING fields only (program, bank, volume, pan, reverb, chorus) —
        /// `name`, `midiChannel`, and `midiPort` are identity/routing metadata from the rendered SMF, not part of what
        /// makes two instances sound alike. `InstrumentChannel`'s synthesized `Hashable` covers every stored field, so
        /// a literal per-instance value (declared channel included) would never collapse two instances MuseScore gave
        /// different channel numbers to — exactly the case this dedup exists to catch. Zeroing those three fields
        /// before hashing keeps `InstrumentChannel`'s own conformance untouched (still safe to hand off to a
        /// dictionary elsewhere) while keying this dictionary on sound alone.
        private static func soundKey(_ instrument: Instrument) -> InstrumentChannel {
            var flavour = instrument.channel
            flavour.name = nil
            flavour.midiChannel = nil
            flavour.midiPort = nil
            // The score's mute / solo say whether a strip is heard, not what it sounds like: a muted instance of an
            // instrument still shares its strip, so saving a mute never splits one strip into two.
            flavour.isMuted = false
            flavour.isSoloed = false
            return flavour
        }

        private mutating func newStrip(_ partIndex: Int, _ instrument: Instrument, key: InstrumentChannel) -> Int {
            let ordinal = strips.count { $0.partIndex == partIndex }
            ordinalForSound[partIndex][key] = ordinal
            let liveChannel = instrument.useDrumset ? MidiRenderer.drumChannel : takeLiveChannel()
            strips.append(Strip(
                partIndex: partIndex, ordinal: ordinal, instrument: instrument, liveChannel: liveChannel,
            ))
            return ordinal
        }

        private mutating func takeLiveChannel() -> Int {
            let channel = MidiRenderer.melodicChannels[nextMelodic % MidiRenderer.melodicChannels.count]
            nextMelodic += 1
            return channel
        }

        /// Records the point's strip, and sends every rendered assignment of the point — all its `<Channel>`
        /// flavours — to that strip's live channel.
        @discardableResult
        private mutating func place(_ index: Int, ordinal: Int, partIndex: Int) -> Int {
            ordinals[partIndex][index] = ordinal
            let liveChannel = strips.last { $0.partIndex == partIndex && $0.ordinal == ordinal }?.liveChannel ?? 0
            let partAssignments = assignments.indices.contains(partIndex) ? assignments[partIndex] : []
            for assignment in partAssignments where assignment.instrumentOrdinal == index {
                remap[assignment.key] = liveChannel
            }
            return liveChannel
        }
    }
}
