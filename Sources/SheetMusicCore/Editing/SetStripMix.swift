import SheetMusicFoundation

/// One mixer strip's sound as the score should state it: what a host's "save this mix to the score" writes.
///
/// A strip is addressed by the points of its part's sound timeline (`Score.soundTimeline(forPart:)`) that play on
/// it, not by the strip ordinal a live mixer shows: the ordinals are assigned by `LiveChannelPlan` in the MIDI layer,
/// keyed on the very sounding fields this edit changes, so they cannot be resolved here and would not survive the
/// edit anyway. A host maps its strip to points with `LiveChannelPlan.timelineIndices(partIndex:ordinal:)`.
public struct StripMix: Sendable, Equatable, Hashable {
    public var partIndex: Int
    /// Sound-timeline indices of the part that play on this strip.
    public var points: [Int]
    /// CC 7, `0 ... 127`.
    public var volume: Int
    /// GM program, `0 ... 127`.
    public var program: Int
    public var isMuted: Bool
    public var isSoloed: Bool

    public init(partIndex: Int, points: [Int], volume: Int, program: Int, isMuted: Bool, isSoloed: Bool) {
        self.partIndex = partIndex
        self.points = points
        self.volume = volume
        self.program = program
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

/// Writes each strip's volume, program, mute and solo into the channels its points sound through, as one undo step.
///
/// - An instrument point (the part's own instrument, or a mid-score instrument change) writes its instrument's
///   primary `<Channel>` — the one a live mixer keys the strip on. Its other channels are technique flavours with
///   strips of their own.
/// - A play-technique point that sounds through one of its instrument's own channels (`pizzicato`, …) writes that
///   channel.
/// - A technique point with no channel of its own (a General MIDI sound chosen for the technique) has nothing in the
///   score to write to, and is skipped.
///
/// Changes no structure, so nothing is re-derived and nothing re-stamped. Writing the sounding fields can merge or
/// split a live mixer's strips on the next build; a host re-reads its strips after the edit.
public struct SetStripMix: EditCommand {
    /// Where a channel lives in the score.
    enum Slot: Hashable {
        case partInstrument(partIndex: Int, channel: Int)
        case change(measureIndex: Int, elementIndex: Int, channel: Int)
    }

    private enum Payload {
        case mixes([StripMix])
        /// The inverse: the exact channels the forward edit found.
        case restores([Slot: InstrumentChannel])
    }

    private let payload: Payload
    public let affectedLocation: VoiceElementID

    public init(_ mixes: [StripMix]) {
        payload = .mixes(mixes)
        affectedLocation = Self.location(partIndex: mixes.first?.partIndex ?? 0)
    }

    private init(restoring channels: [Slot: InstrumentChannel], location: VoiceElementID) {
        payload = .restores(channels)
        affectedLocation = location
    }

    private static func location(partIndex: Int) -> VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    /// Whether applying would leave the score as it is — the planner reports that as nothing to apply.
    func changesNothing(in score: Score) -> Bool {
        guard case let .mixes(mixes) = payload, let writes = try? Self.writes(for: mixes, in: score) else {
            return false
        }
        return writes.allSatisfy { slot, write in
            Self.channel(at: slot, in: score).map { write($0) == $0 } ?? false
        }
    }

    @discardableResult
    public func apply(to score: inout Score, ids _: inout EIDAllocator) throws -> any EditCommand {
        var previous: [Slot: InstrumentChannel] = [:]
        switch payload {
        case let .mixes(mixes):
            let writes: [Slot: (InstrumentChannel) -> InstrumentChannel]
            do {
                writes = try Self.writes(for: mixes, in: score)
            } catch {
                throw Self.refused(.targetNotFound(affectedLocation))
            }
            for (slot, write) in writes {
                guard let current = Self.channel(at: slot, in: score) else {
                    throw Self.refused(.targetNotFound(affectedLocation))
                }
                previous[slot] = current
                Self.setChannel(write(current), at: slot, in: &score)
            }
        case let .restores(channels):
            for (slot, channel) in channels {
                guard let current = Self.channel(at: slot, in: score) else {
                    throw Self.refused(.targetNotFound(affectedLocation))
                }
                previous[slot] = current
                Self.setChannel(channel, at: slot, in: &score)
            }
        }
        return SetStripMix(restoring: previous, location: affectedLocation)
    }

    private struct UnknownPoint: Error {}

    /// Every channel the mixes write, with how each is rewritten. A slot two strips both reach takes the later one.
    private static func writes(
        for mixes: [StripMix], in score: Score,
    ) throws -> [Slot: (InstrumentChannel) -> InstrumentChannel] {
        var writes: [Slot: (InstrumentChannel) -> InstrumentChannel] = [:]
        for mix in mixes {
            guard score.parts.indices.contains(mix.partIndex) else { throw UnknownPoint() }
            let timeline = score.soundTimeline(forPart: mix.partIndex)
            let instrumentSlots = instrumentSlots(ofPart: mix.partIndex, in: score)
            // The k-th instrument point of the sound timeline is the k-th entry of the instrument timeline.
            var instrumentOrdinal: [Int: Int] = [:]
            for (index, point) in timeline.enumerated() where point.basePoint == nil {
                instrumentOrdinal[index] = instrumentOrdinal.count
            }
            for index in mix.points {
                guard timeline.indices.contains(index) else { throw UnknownPoint() }
                let point = timeline[index]
                let slot: Slot
                if let ordinal = instrumentOrdinal[index] {
                    guard instrumentSlots.indices.contains(ordinal) else { throw UnknownPoint() }
                    slot = instrumentSlots[ordinal].withChannel(0)
                } else if let source = point.flavourSource, let ordinal = instrumentOrdinal[source.point],
                          instrumentSlots.indices.contains(ordinal)
                {
                    slot = instrumentSlots[ordinal].withChannel(source.flavour)
                } else {
                    continue
                }
                writes[slot] = { channel in
                    var channel = channel
                    channel.volume = min(max(mix.volume, 0), 127)
                    channel.program = min(max(mix.program, 0), 127)
                    channel.isMuted = mix.isMuted
                    channel.isSoloed = mix.isSoloed
                    return channel
                }
            }
        }
        return writes
    }

    /// The part's instrument timeline as places in the score: the part's own instrument, then each instrument change
    /// on the part in the order `instrumentTimeline(forPart:)` walks them. Channel `0` is a placeholder.
    private static func instrumentSlots(ofPart partIndex: Int, in score: Score) -> [Slot] {
        var slots: [Slot] = [.partInstrument(partIndex: partIndex, channel: 0)]
        for (measureIndex, measure) in score.systemMeasures.enumerated() {
            for (elementIndex, positioned) in measure.elements.enumerated() {
                guard case let .instrumentChange(change) = positioned.element, change.instrument != nil,
                      positioned.originalStaff?.partIndex == partIndex
                else { continue }
                slots.append(.change(measureIndex: measureIndex, elementIndex: elementIndex, channel: 0))
            }
        }
        return slots
    }

    private static func channel(at slot: Slot, in score: Score) -> InstrumentChannel? {
        let instrument: Instrument?
        let channel: Int
        switch slot {
        case let .partInstrument(partIndex, index):
            instrument = score.parts.indices.contains(partIndex) ? score.parts[partIndex].instrument : nil
            channel = index
        case let .change(measureIndex, elementIndex, index):
            instrument = changeInstrument(measureIndex: measureIndex, elementIndex: elementIndex, in: score)
            channel = index
        }
        guard let instrument else { return nil }
        if instrument.channels.isEmpty, channel == 0 { return InstrumentChannel() }
        return instrument.channels.indices.contains(channel) ? instrument.channels[channel] : nil
    }

    private static func changeInstrument(measureIndex: Int, elementIndex: Int, in score: Score) -> Instrument? {
        guard score.systemMeasures.indices.contains(measureIndex),
              score.systemMeasures[measureIndex].elements.indices.contains(elementIndex),
              case let .instrumentChange(change) = score.systemMeasures[measureIndex].elements[elementIndex].element
        else { return nil }
        return change.instrument
    }

    private static func setChannel(_ value: InstrumentChannel, at slot: Slot, in score: inout Score) {
        func write(_ instrument: inout Instrument, _ index: Int) {
            if instrument.channels.isEmpty, index == 0 {
                instrument.channels = [value]
            } else if instrument.channels.indices.contains(index) {
                instrument.channels[index] = value
            }
        }
        switch slot {
        case let .partInstrument(partIndex, index):
            score.parts.updateValue(at: partIndex) { write(&$0.instrument, index) }
        case let .change(measureIndex, elementIndex, index):
            score.systemMeasures.updateValue(at: measureIndex) { measure in
                measure.elements.updateValue(at: elementIndex) { positioned in
                    guard case var .instrumentChange(change) = positioned.element,
                          var instrument = change.instrument
                    else { return }
                    write(&instrument, index)
                    change.instrument = instrument
                    positioned.element = .instrumentChange(change)
                }
            }
        }
    }
}

extension SetStripMix.Slot {
    fileprivate func withChannel(_ channel: Int) -> Self {
        switch self {
        case let .partInstrument(partIndex, _): .partInstrument(partIndex: partIndex, channel: channel)
        case let .change(measureIndex, elementIndex, _):
            .change(measureIndex: measureIndex, elementIndex: elementIndex, channel: channel)
        }
    }
}
