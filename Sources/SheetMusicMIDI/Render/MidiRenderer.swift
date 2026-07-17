import Foundation
import SheetMusicCore

/// Renders a `Score` into a `MidiFile`. The implementation is split across
/// `MidiRenderer+*.swift` extensions for: header emission, channel allocation,
/// per-voice walking (with arpeggio), repeat-list expansion, MeasureRepeat
/// resolution, and the unison-overlap merge step.
public enum MidiRenderer {
    /// Default base velocity for "mf" when no Dynamic has been seen.
    static let defaultDynamicVelocity = 80

    /// Default tempo if the score has no Tempo markers (120 BPM = 500000 µs/quarter).
    static let defaultMicrosPerQuarter = 500_000

    /// Render the given `Score` into a `MidiFile` ready for serialization.
    public static func render(score: Score) throws -> MidiFile {
        // Hold each tie chain at its head note's sounding pitch so a tie
        // whose endpoints differ in pitch (e.g. C♯ tied across a key change
        // into an invisible C-double-sharp) doesn't leave a stuck note.
        let score = resolvingTiedPitches(in: score)
        var tracks: [MidiTrack] = []
        let channelAssignments = assignChannels(score: score)
        var trackIndex = 0
        // Per-staff swing maps mirror MuseScore's `Score::updateSwing`
        // (score.cpp:6081): SystemText-flagged swing markers fan out to
        // every staff so the whole system swings; staff-flagged ones
        // stay on their owning staff.
        let swingMaps = collectSwingMaps(
            score: score, division: score.division,
        )
        // ONE score-global unroll plan shared by every staff.
        // Jumps/markers are written only on the top staff (MuseScore
        // convention), so a per-staff plan would jump on staff 0 and
        // play linearly on staves 1..n, desyncing the tracks.
        // Repeats/voltas replicate across staves and measure tick
        // spans are globally identical, so one plan is consistent
        // for all. Mirrors RepeatList being a Score-level singleton
        // in MuseScore (masterscore's repeatList()).
        let navigation = ScoreNavigation(score: score)
        let plan = RepeatUnwinder.plan(navigation: navigation)
        for (partIndex, part) in score.parts.enumerated() {
            let channels = channelAssignments[partIndex]
            let primaryChannel = channels.first?.channel ?? partIndex
            let port = part.instrument.channel.midiPort ?? 0
            for (s, staff) in part.staves.enumerated() {
                let address = StaffAddress(
                    partIndex: partIndex,
                    staffIndexInPart: s,
                )
                let systemElementsForStaff = filterSystemElements(
                    score: score, forStaff: address,
                )
                let track = try renderTrack(
                    staff: staff,
                    part: part,
                    plan: plan,
                    primaryChannel: primaryChannel,
                    channels: channels,
                    port: port,
                    isFirstTrack: trackIndex == 0,
                    isTopOfPart: s == 0,
                    division: score.division,
                    swingMap: trackIndex < swingMaps.count
                        ? swingMaps[trackIndex]
                        : .empty,
                    systemElementsByMeasure: systemElementsForStaff,
                )
                tracks.append(track)
                trackIndex += 1
            }
        }
        return MidiFile(division: score.division, format: 1, tracks: tracks)
    }

    /// System elements destined for a given staff: those whose
    /// `originalStaff` matches `address`, plus those with `nil`
    /// `originalStaff` routed to the canonical staff (0,0).
    /// Returned shape: outer array indexed by measure number.
    static func filterSystemElements(
        score: Score, forStaff address: StaffAddress,
    ) -> [[PositionedSystemElement]] {
        let canonical = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        return score.systemMeasures.map { measure in
            measure.elements.filter { element in
                (element.originalStaff ?? canonical) == address
            }
        }
    }

    /// One MIDI channel allocated to a particular `<Channel>` flavour of a part.
    struct ChannelAssignment {
        var channel: Int
        var flavour: InstrumentChannel
    }

    private static func renderTrack(
        staff: Staff,
        part: Part,
        plan: [PlaybackEntry],
        primaryChannel: Int,
        channels: [ChannelAssignment],
        port: Int,
        isFirstTrack: Bool,
        isTopOfPart: Bool,
        division: Int,
        swingMap: SwingMap,
        systemElementsByMeasure: [[PositionedSystemElement]],
    ) throws -> MidiTrack {
        var events: [TimedMidiEvent] = headerEvents(
            staff: staff,
            part: part,
            channels: channels,
            port: port,
            isFirstTrack: isFirstTrack,
            isTopOfPart: isTopOfPart,
        )

        // Per-staff fermata ranges + tempo bookends. Built BEFORE
        // voice walks so close events sort ahead of any same-tick
        // `.tempo` from those walks; open events are appended AFTER
        // so they sort after same-tick `.tempo`. The renderer's
        // stable sort below realises the documented close → .tempo
        // → open ordering at boundary ticks.
        //
        // Bookends are collected at original (pre-repeat) ticks; we
        // project them through `playbackPlan` so each repeat
        // iteration re-fires its own pair. Without this projection a
        // fermata inside `<startRepeat>...<endRepeat>` would hold
        // only on the first take.
        let fermataRanges = FermataRanges.collect(from: staff, division: division)
        let staffSystemMeasures = systemElementsByMeasure.map {
            SystemMeasure(elements: $0)
        }
        let timeline = TempoTimeline.build(
            measures: staff.measures,
            systemMeasures: staffSystemMeasures,
            division: division,
        )
        let bookends = FermataRanges.tempoEvents(
            ranges: fermataRanges, timeline: timeline,
        )
        let (measureBases, measureSpans) = measureBaseLayout(
            measures: staff.measures, division: division,
        )
        let projectedClose = projectBookends(
            bookends.closeEvents, plan: plan,
            measureBases: measureBases, measureSpans: measureSpans,
        )
        let projectedOpen = projectBookends(
            bookends.openEvents, plan: plan,
            measureBases: measureBases, measureSpans: measureSpans,
        )

        events.append(contentsOf: projectedClose)

        var voiceEventBuckets: [[TimedMidiEvent]] = []
        var lyricAnchors: [LyricMidiCodec.Anchor] = []
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0 ..< voiceCount {
            let (voiceEvents, _, anchors) = try renderVoice(
                voiceIndex: voiceIndex,
                staff: staff,
                part: part,
                channel: primaryChannel,
                division: division,
                plan: plan,
                swingMap: swingMap,
                systemElementsByMeasure: systemElementsByMeasure,
            )
            voiceEventBuckets.append(voiceEvents)
            lyricAnchors.append(contentsOf: anchors)
        }
        // Multi-voice merge resolves same-pitch overlaps (the "muted unison" case).
        let merged = resolveUnisonOverlap(voiceEventBuckets.flatMap(\.self))
        events.append(contentsOf: merged)

        events.append(contentsOf: lyricEvents(from: lyricAnchors))

        events.append(contentsOf: projectedOpen)

        // EoT lands one tick after the last produced event (MuseScore convention):
        // for note-bearing tracks this is final-noteOff + 1; for empty tracks it's 1.
        let lastEventTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastEventTick + 1, event: .endOfTrack))

        // Stable sort by tick — preserves header insertion order at tick 0
        // and keeps voice-0 events ahead of voice-1 events at the same tick.
        // Negative ticks are clamped to 0 as a safety net: the decoder is the
        // source of truth for positions, but a malformed `<location>` could
        // still drive an event before the bar start, and a negative tick trips
        // `MidiWriter`'s sorted-by-tick precondition (a hard crash). Clamping a
        // sorted prefix of negatives to 0 keeps the sequence non-decreasing.
        let sorted = events.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map { TimedMidiEvent(tick: max(0, $0.element.tick), event: $0.element.event) }

        return MidiTrack(events: sorted)
    }

    /// Pack chord lyrics into standard SMF Lyric (0x05) meta events.
    /// Lyrics from all voices share one per-track stream; in the rare
    /// case two voices carry lyrics at the same tick the later voice
    /// wins (multi-voice lyric overlap is out of scope).
    private static func lyricEvents(
        from anchors: [LyricMidiCodec.Anchor],
    ) -> [TimedMidiEvent] {
        LyricMidiCodec.encode(anchors.sorted { $0.tick < $1.tick }).map { event in
            TimedMidiEvent(tick: event.tick, event: .meta(.lyric(event.text)))
        }
    }

    /// Project a list of bookend events (originally collected at
    /// pre-repeat ticks) through the unrolled `playbackPlan`. For
    /// every plan entry whose `measureIndex` matches the event's
    /// owning measure, a copy is emitted at the playback tick
    /// `entry.tickOffset + (event.tick - measureBases[mi])`.
    ///
    /// Close events sit on the boundary between measures; an event
    /// at `measureBases[mi] + measureSpans[mi]` is attributed to
    /// measure `mi` (the bar that just ended) rather than `mi + 1`.
    /// This matches how a fermata's anchor chord ends the bar it
    /// lives in.
    private static func projectBookends(
        _ bookends: [TimedMidiEvent],
        plan: [PlaybackEntry],
        measureBases: [Int],
        measureSpans: [Int],
    ) -> [TimedMidiEvent] {
        guard !bookends.isEmpty, !plan.isEmpty else { return [] }
        var out: [TimedMidiEvent] = []
        for event in bookends {
            guard let mi = ownerMeasureIndex(
                forTick: event.tick,
                measureBases: measureBases,
                measureSpans: measureSpans,
            ) else { continue }
            let offsetWithinMeasure = event.tick - measureBases[mi]
            for entry in plan where entry.measureIndex == mi {
                out.append(TimedMidiEvent(
                    tick: entry.tickOffset + offsetWithinMeasure,
                    event: event.event,
                ))
            }
        }
        return out
    }

    /// Per-measure (base, span) tick budgets for the staff. Resolves
    /// each measure's effective duration so `.measure` rests get the
    /// correct concrete fraction before tick computation.
    private static func measureBaseLayout(
        measures: [Measure], division: Int,
    ) -> (bases: [Int], spans: [Int]) {
        var bases: [Int] = []
        var spans: [Int] = []
        let measureDurations = measures.effectiveMeasureDurations()
        var acc = 0
        for (i, m) in measures.enumerated() {
            bases.append(acc)
            let mDur = i < measureDurations.count
                ? measureDurations[i]
                : Fraction(numerator: 4, denominator: 4)
            let span = measureTicks(
                measure: m, division: division,
                measureDuration: mDur,
            )
            spans.append(span)
            acc += span
        }
        return (bases, spans)
    }

    /// Half-open lookup `[base, base + span)` with one tweak: a tick
    /// sitting exactly on the closing boundary belongs to the
    /// measure that just ended (so close bookends at endTick stay
    /// with their anchor chord's bar).
    private static func ownerMeasureIndex(
        forTick tick: Int,
        measureBases: [Int],
        measureSpans: [Int],
    ) -> Int? {
        for i in 0 ..< measureBases.count {
            let base = measureBases[i]
            let end = base + measureSpans[i]
            if tick >= base && tick < end {
                return i
            }
            if tick == end {
                return i
            }
        }
        return nil
    }
}
