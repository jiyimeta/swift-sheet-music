import SheetMusicCore
import SheetMusicFoundation

// swiftlint:disable file_length

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
    ///
    /// Pedals do not play yet: `SustainPedal` is built and tested, but the Android and Windows engines have not been
    /// checked for releasing the damper on stop, so no CC64 goes out until they are.
    public static func render(score: Score) throws -> MidiFile {
        try render(score: score, includingSustainPedal: false)
    }

    /// `render(score:)` with the choke marker (`ChokeMarker`) at the end of every choked tie chain, for a sequence a
    /// synthesizer plays rather than a file a user exports. `renderForPlayback(score:)` turns it on; so does an audio
    /// export that renders through a `SynthBackend`.
    public static func render(score: Score, emittingChokes: Bool) throws -> MidiFile {
        try render(score: score, includingSustainPedal: false, emitsChokes: emittingChokes)
    }

    /// `render(score:)` with the sustain pedal switched on — the path pedal playback will take once every engine
    /// releases the damper on stop; its tests run it today. `emitsChokes` adds the choke marker
    /// (`render(score:emittingChokes:)`).
    static func render( // swiftlint:disable:this function_body_length
        score: Score, includingSustainPedal: Bool, emitsChokes: Bool = false,
    ) throws -> MidiFile {
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
        // The tempo map, built once for the whole render: every bar-length walk below reads it.
        let tempoMap = score.resolvedTempoMap()
        let swingMaps = collectSwingMaps(
            score: score, division: score.division, tempoMap: tempoMap,
        )
        // ONE score-global unroll plan shared by every staff.
        // Jumps/markers are written only on the top staff (MuseScore
        // convention), so a per-staff plan would jump on staff 0 and
        // play linearly on staves 1..n, desyncing the tracks.
        // Repeats/voltas replicate across staves and measure tick
        // spans are globally identical, so one plan is consistent
        // for all. Mirrors RepeatList being a Score-level singleton
        // in MuseScore (masterscore's repeatList()).
        let navigation = ScoreNavigation(score: score, tempoMap: tempoMap)
        let plan = RepeatUnwinder.plan(navigation: navigation)
        // ONE score-global set of fermata tempo bookends, emitted into the first track only.
        // Tempo metas are score-global once a sequencer merges the tracks, so a per-staff build was
        // wrong twice: it duplicated every system fermata's pair across staves, and — because
        // `filterSystemElements` hands a system-level `<Tempo>` to the canonical staff alone —
        // staves 1…n computed their bookends against the 120 BPM default, whose CLOSE event then
        // reset the merged tempo map to 120 BPM for the rest of the piece.
        //
        // Bookends are collected at original (pre-repeat) ticks; projecting them through
        // `playbackPlan` makes each repeat iteration re-fire its own pair, so a fermata inside
        // `<startRepeat>…<endRepeat>` holds on every take rather than only the first.
        let bookends = fermataBookendEvents(score: score, tempoMap: tempoMap)
        let canonicalLayout = measureBaseLayout(
            measures: score.parts.first?.staves.first?.measures ?? [], division: score.division,
            tempoMap: tempoMap,
        )
        let projectedFermataClose = projectBookends(
            bookends.closeEvents, opening: false, plan: plan,
            measureBases: canonicalLayout.bases, measureSpans: canonicalLayout.spans,
        )
        let projectedFermataOpen = projectBookends(
            bookends.openEvents, opening: true, plan: plan,
            measureBases: canonicalLayout.bases, measureSpans: canonicalLayout.spans,
        )
        for (partIndex, part) in score.parts.enumerated() {
            let channels = channelAssignments[partIndex]
            let route = PartChannelRoute.build(
                score: score, partIndex: partIndex, assignments: channels,
            )
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
                    staffIndex: s,
                    part: part,
                    plan: plan,
                    route: route,
                    channels: channels,
                    isFirstTrack: trackIndex == 0,
                    isTopOfPart: s == 0,
                    includingSustainPedal: includingSustainPedal,
                    emitsChokes: emitsChokes,
                    division: score.division,
                    swingMap: trackIndex < swingMaps.count
                        ? swingMaps[trackIndex]
                        : .empty,
                    systemElementsByMeasure: systemElementsForStaff,
                    tempoMap: tempoMap,
                    fermataCloseEvents: trackIndex == 0 ? projectedFermataClose : [],
                    fermataOpenEvents: trackIndex == 0 ? projectedFermataOpen : [],
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

    /// One MIDI channel allocated to a particular `<Channel>` flavour of
    /// one instrument in force somewhere in a part.
    struct ChannelAssignment {
        var channel: Int
        /// Declared `<midiPort>` (0 when absent). Part of the channel's
        /// identity — see `MidiChannelKey`.
        var port: Int
        var flavour: InstrumentChannel
        /// Index into `Score.soundTimeline(forPart:)`: 0 = the tick-0
        /// instrument, then one per change instance and per play
        /// technique's new sound.
        var instrumentOrdinal: Int

        var key: MidiChannelKey {
            MidiChannelKey(port: port, channel: channel)
        }
    }

    /// Ordered channel switches for one part, expressed in the SAME
    /// measure-relative space `Score.soundTimeline` returns.
    ///
    /// Kept measure-relative until the last moment: the absolute tick is
    /// resolved against the STAFF'S OWN `measureBases`, so this walker
    /// cannot drift from the voice walker that consumes it (breath
    /// pauses count toward a bar's budget in `measureTicks`, and a
    /// second independent derivation would disagree).
    struct PartChannelRoute {
        let defaultChannel: Int
        /// Declared `<midiPort>` of the tick-0 instrument. The port a
        /// track's events sit under until the first switch onto a
        /// different one — see `MidiRenderer.portSwitchEvents`.
        let defaultPort: Int
        /// Sorted by `measureIndex` then `position`.
        let switches: [Switch]

        /// One instrument-change channel switch, measure-relative.
        struct Switch {
            let measureIndex: Int
            let position: MeasurePosition
            let channel: Int
            /// Declared `<midiPort>` of the instrument switched TO.
            /// A channel number alone is not an address: port 1's
            /// channel 0 is a different destination from port 0's.
            let port: Int
        }

        /// True when every instrument in force in this part declares the
        /// same `<midiPort>`. Such a part needs no mid-track `portChange`,
        /// so its rendered track is unchanged from a portless renderer.
        var isSinglePort: Bool {
            switches.allSatisfy { $0.port == defaultPort }
        }

        /// Build from the part's sound timeline plus its channel assignments.
        /// Assignment `ordinal` indexes the sound timeline, and the FIRST
        /// flavour of each instrument is the sounding one; a play technique
        /// that selects one of the instrument's other `<Channel>`s sounds on
        /// that flavour's channel, and a point that sounds like an earlier
        /// one on that point's.
        static func build(
            score: Score, partIndex: Int, assignments: [ChannelAssignment],
        ) -> PartChannelRoute {
            let timeline = score.soundTimeline(forPart: partIndex)
            var routeByOrdinal: [Int: (channel: Int, port: Int)] = [:]
            for assignment in assignments
                where routeByOrdinal[assignment.instrumentOrdinal] == nil
            {
                routeByOrdinal[assignment.instrumentOrdinal] =
                    (assignment.channel, assignment.port)
            }
            for (ordinal, point) in timeline.enumerated() where routeByOrdinal[ordinal] == nil {
                if let source = point.flavourSource {
                    let flavours = assignments.filter { $0.instrumentOrdinal == source.point }
                    if flavours.indices.contains(source.flavour) {
                        routeByOrdinal[ordinal] = (flavours[source.flavour].channel, flavours[source.flavour].port)
                    }
                } else if let earlier = point.reusesPoint {
                    routeByOrdinal[ordinal] = routeByOrdinal[earlier]
                } else if let base = point.basePoint {
                    // A technique whose sound found no free channel sounds as its instrument.
                    routeByOrdinal[ordinal] = routeByOrdinal[base]
                }
            }
            var switches: [Switch] = []
            for (ordinal, point) in timeline.enumerated() where ordinal > 0 {
                guard let entry = routeByOrdinal[ordinal] else { continue }
                switches.append(Switch(
                    measureIndex: point.measureIndex,
                    position: point.position,
                    channel: entry.channel,
                    port: entry.port,
                ))
            }
            return PartChannelRoute(
                defaultChannel: routeByOrdinal[0]?.channel ?? partIndex,
                defaultPort: routeByOrdinal[0]?.port ?? 0,
                switches: switches,
            )
        }

        /// Channel in force at `tick`, given this route flattened by `routeByOriginalTick`. The same scan as the local
        /// `channel(atOriginalTick:)` in `renderVoice`, which stays untouched.
        func channel(atOriginalTick tick: Int, in flattened: [(tick: Int, channel: Int, port: Int)]) -> Int {
            var result = defaultChannel
            for entry in flattened {
                if entry.tick <= tick { result = entry.channel } else { break }
            }
            return result
        }

        /// Flatten to `(originalTick, channel, port)` triples against a
        /// staff's own measure bases, sorted ascending. Switches whose
        /// measure index is out of range for a ragged staff are dropped.
        func routeByOriginalTick(
            measureBases: [Int], division: Int,
        ) -> [(tick: Int, channel: Int, port: Int)] {
            switches.compactMap { entry in
                guard measureBases.indices.contains(entry.measureIndex)
                else { return nil }
                return (
                    measureBases[entry.measureIndex]
                        + entry.position.ticks(division: division),
                    entry.channel,
                    entry.port,
                )
            }
            .sorted { $0.tick < $1.tick }
        }
    }

    private static func renderTrack(
        staff: Staff,
        staffIndex: Int,
        part: Part,
        plan: [PlaybackEntry],
        route: PartChannelRoute,
        channels: [ChannelAssignment],
        isFirstTrack: Bool,
        isTopOfPart: Bool,
        includingSustainPedal: Bool,
        emitsChokes: Bool,
        division: Int,
        swingMap: SwingMap,
        systemElementsByMeasure: [[PositionedSystemElement]],
        tempoMap: ResolvedTempoMap,
        fermataCloseEvents: [TimedMidiEvent],
        fermataOpenEvents: [TimedMidiEvent],
    ) throws -> MidiTrack {
        var events: [TimedMidiEvent] = headerEvents(
            staff: staff,
            part: part,
            channels: channels,
            defaultPort: route.defaultPort,
            isFirstTrack: isFirstTrack,
            isTopOfPart: isTopOfPart,
        )

        // The score-global fermata bookends `render(score:)` computed, non-empty on the first track
        // only. Close events go in BEFORE the voice walks so they sort ahead of any same-tick
        // `.tempo` from those walks; open events are appended AFTER so they sort after one. The
        // stable sort below realises the documented close → .tempo → open ordering at boundary
        // ticks.
        let layout = measureBaseLayout(
            measures: staff.measures, division: division, tempoMap: tempoMap,
        )
        let measureBases = layout.bases

        events.append(contentsOf: fermataCloseEvents)

        // Mid-track `portChange` metas for a part that spans two ports.
        // Appended BEFORE the voice walks so the stable sort below puts
        // each meta ahead of the same-tick notes it governs. A no-op for
        // every single-port part.
        events.append(contentsOf: portSwitchEvents(
            route: route, plan: plan, measureBases: measureBases, division: division,
        ))

        // Sustain pedal (CC64): every staff's pedals go into the part's first track, one stream per part, so a release
        // and a press on the shared channel at one tick keep their order (`SustainPedal.events(part:…)`).
        if includingSustainPedal, isTopOfPart {
            events.append(contentsOf: SustainPedal.events(
                part: part, route: route, plan: plan,
                layout: { measureBaseLayout(measures: $0.measures, division: division, tempoMap: tempoMap) },
                division: division, tempoMap: tempoMap,
            ))
        }

        var voiceEventBuckets: [[TimedMidiEvent]] = []
        var lyricAnchors: [LyricMidiCodec.Anchor] = []
        // What the tempo-writing walk reads to tell what the track plays at a repeat jump (`tempoEvents`).
        let bookends = BookendTempoTrack(close: fermataCloseEvents, open: fermataOpenEvents)
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0 ..< voiceCount {
            let (voiceEvents, _, anchors) = try renderVoice(
                voiceIndex: voiceIndex,
                staffIndex: staffIndex,
                staff: staff,
                part: part,
                route: route,
                division: division,
                plan: plan,
                swingMap: swingMap,
                systemElementsByMeasure: systemElementsByMeasure,
                tempoMap: tempoMap,
                emitsTempoEvents: isFirstTrack && voiceIndex == 0,
                bookends: bookends,
                emitsChokes: emitsChokes,
            )
            voiceEventBuckets.append(voiceEvents)
            lyricAnchors.append(contentsOf: anchors)
        }
        // Multi-voice merge resolves same-pitch overlaps (the "muted unison" case).
        let merged = resolveUnisonOverlap(voiceEventBuckets.flatMap(\.self))
        events.append(contentsOf: merged)

        events.append(contentsOf: lyricEvents(from: lyricAnchors))

        events.append(contentsOf: fermataOpenEvents)

        // EoT lands one tick after the last produced event (MuseScore convention):
        // for note-bearing tracks this is final-noteOff + 1; for empty tracks it's 1.
        let lastEventTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastEventTick + 1, event: .endOfTrack))

        // Last, once every note-on is in its place: the microtonal offsets the emit annotated become wheel traffic.
        return MidiTrack(events: MicrotonalPitchWheel.apply(
            sortedByTick(events), releaseTicks: division / 2, exemptChannels: [drumChannel],
        ))
    }

    /// Stable sort by tick — preserves header insertion order at tick 0
    /// and keeps voice-0 events ahead of voice-1 events at the same tick.
    /// Negative ticks are clamped to 0 as a safety net: the decoder is the
    /// source of truth for positions, but a malformed `<location>` could
    /// still drive an event before the bar start, and a negative tick trips
    /// `MidiWriter`'s sorted-by-tick precondition (a hard crash). Clamping a
    /// sorted prefix of negatives to 0 keeps the sequence non-decreasing.
    /// The events are moved, not rebuilt, so a note-on keeps its microtonal annotation.
    private static func sortedByTick(_ events: [TimedMidiEvent]) -> [TimedMidiEvent] {
        events.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map { indexed in
                var event = indexed.element
                event.tick = max(0, event.tick)
                return event
            }
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
    /// An event on a barline belongs to the bar its hold sits in: a close (`opening` false) to the bar that ends
    /// there, whose last chord the hold was on, and an open to the bar that starts there, whose first chord it holds.
    /// No hold crosses a barline, so the sweep's events on one are exactly these. Giving the open to the ending bar too
    /// fired it wherever that bar ended, whatever came next: a fermata on the final bar after `:‖` stretched the whole
    /// second pass from the jump back, and a fermata on a jump target's downbeat held only when the bar before it led
    /// in. Each bar's own hold now plays on every pass of that bar, as the cursor (`UnrolledTimeMap`, which times each
    /// pass by its own bar's notated span) already assumed.
    private static func projectBookends(
        _ bookends: [TimedMidiEvent],
        opening: Bool,
        plan: [PlaybackEntry],
        measureBases: [Int],
        measureSpans: [Int],
    ) -> [TimedMidiEvent] {
        guard !bookends.isEmpty, !plan.isEmpty else { return [] }
        var out: [TimedMidiEvent] = []
        for event in bookends {
            guard let mi = ownerMeasureIndex(
                forTick: event.tick,
                opening: opening,
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
        measures: [Measure], division: Int, tempoMap: ResolvedTempoMap,
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
                measureIndex: i, tempoMap: tempoMap,
            )
            spans.append(span)
            acc += span
        }
        return (bases, spans)
    }

    /// Half-open lookup `[base, base + span)` with one tweak for a
    /// close (`opening` false): a tick sitting exactly on the closing
    /// boundary belongs to the measure that just ended (so close
    /// bookends at endTick stay with their anchor chord's bar). An
    /// open on a barline falls through to the bar that starts there.
    private static func ownerMeasureIndex(
        forTick tick: Int,
        opening: Bool,
        measureBases: [Int],
        measureSpans: [Int],
    ) -> Int? {
        for i in 0 ..< measureBases.count {
            let base = measureBases[i]
            let end = base + measureSpans[i]
            if tick >= base && tick < end {
                return i
            }
            if tick == end && !opening {
                return i
            }
        }
        return nil
    }
}
