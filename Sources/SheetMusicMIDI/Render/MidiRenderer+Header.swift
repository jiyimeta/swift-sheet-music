import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    static func headerEvents(
        staff: Staff,
        part: Part,
        channels: [ChannelAssignment],
        defaultPort: Int,
        isFirstTrack: Bool,
        isTopOfPart: Bool,
    ) -> [TimedMidiEvent] {
        var events: [TimedMidiEvent] = []

        let trackName = part.trackName ?? part.instrument.longName ?? "Track"
        events.append(TimedMidiEvent(tick: 0, event: .meta(.trackName(trackName))))

        // TimeSig and Tempo go only on track 0 (matches MuseScore exportmidi.cpp).
        if isFirstTrack {
            let initialTimeSig = firstTimeSignature(in: staff) ?? TimeSignature(numerator: 4, denominator: 4)
            events.append(TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: initialTimeSig.numerator,
                denominator: initialTimeSig.denominator,
                clocksPerClick: 24,
                thirtySecondsPerQuarter: 8,
            ))))
        }

        let initialKey = firstKeySignature(in: staff) ?? KeySignature(concertKey: 0)
        events.append(TimedMidiEvent(tick: 0, event: .meta(.keySignature(
            sharpsFlats: initialKey.concertKey, isMinor: false,
        ))))

        if isFirstTrack {
            events.append(TimedMidiEvent(tick: 0, event: .meta(.tempo(
                microsecondsPerQuarter: defaultMicrosPerQuarter,
            ))))
        }

        // Per-channel-flavour CC headers + portChange. MuseScore loops over every
        // `<Channel>` of the part's instrument inside this track and emits a full
        // header block per flavour. The program / vol / pan / reverb / chorus
        // block is only on the top staff of the part; portChange is unconditional.
        //
        // The portChange LEADS its block. The meta is positional inside a
        // track (`MidiChannelKey`) — it governs what FOLLOWS it — so a
        // trailing meta would file each flavour's program / volume / pan
        // under the previous flavour's port, and for a part whose
        // instruments span two ports that is a different destination.
        for assignment in channels {
            let channel = assignment.channel
            if (0 ... 127).contains(assignment.port) {
                events.append(TimedMidiEvent(
                    tick: 0, event: .meta(.portChange(port: assignment.port)),
                ))
            }
            if isTopOfPart {
                func cc(_ controller: Int, _ value: Int) {
                    let event = MidiEvent.controlChange(channel: channel, controller: controller, value: value)
                    events.append(TimedMidiEvent(tick: 0, event: event))
                }

                cc(121, 0)
                if channel != 9 {
                    cc(100, 0)
                    cc(101, 0)
                    cc(6, 12)
                    cc(100, 127)
                    cc(101, 127)
                }

                let flavour = assignment.flavour
                let programEvent = MidiEvent.programChange(channel: channel, program: flavour.program)
                events.append(TimedMidiEvent(tick: 0, event: programEvent))
                cc(7, flavour.volume)
                cc(10, flavour.pan)
                cc(91, flavour.reverb)
                cc(93, flavour.chorus)
            }
        }

        // Leave the tick-0 instrument's port in force for the notes that
        // follow the header. Without this the LAST header block's port
        // would govern them, so a part that changes onto a second port
        // would route even its pre-change bars to the post-change
        // destination. Skipped when every block already declared the
        // same port, which keeps a single-port track's meta stream
        // exactly as it was.
        let needsRestore = channels.contains { $0.port != defaultPort }
        if needsRestore, (0 ... 127).contains(defaultPort) {
            events.append(TimedMidiEvent(
                tick: 0, event: .meta(.portChange(port: defaultPort)),
            ))
        }
        return events
    }

    /// `portChange` metas at the instrument-change ticks of a part whose
    /// instruments span more than one declared `<midiPort>`.
    ///
    /// The port meta is positional inside a track: the last one seen
    /// governs the events that follow (`MidiChannelKey`). `headerEvents`
    /// leaves the tick-0 port in force, so every subsequent switch onto
    /// a different port needs its own meta — otherwise the whole track
    /// reads as one port and `MidiChannelRemap` sends the notes to the
    /// wrong live mixer strip.
    ///
    /// These are NOT program changes: every program stays at tick 0.
    /// Emitted only when the part actually spans two ports, so a
    /// single-port score's rendered track is untouched.
    ///
    /// Ticks are projected through the unrolled `plan`, exactly as the
    /// voice walker projects its channel switches, so a change inside a
    /// repeated section re-fires on every take and a jump back before
    /// the change restores the earlier port.
    static func portSwitchEvents(
        route: PartChannelRoute,
        plan: [PlaybackEntry],
        measureBases: [Int],
        division: Int,
    ) -> [TimedMidiEvent] {
        guard !route.isSinglePort else { return [] }
        let flattened = route.routeByOriginalTick(
            measureBases: measureBases, division: division,
        )
        /// Port in force at `originalTick` — the same walk
        /// `renderVoice` does for the channel, so the two cannot drift.
        func port(atOriginalTick tick: Int) -> Int {
            var result = route.defaultPort
            for entry in flattened {
                if entry.tick <= tick { result = entry.port } else { break }
            }
            return result
        }

        var events: [TimedMidiEvent] = []
        var current = route.defaultPort
        for entry in plan {
            guard measureBases.indices.contains(entry.measureIndex)
            else { continue }
            // Candidate ports inside this playback iteration of the
            // measure, in ascending tick order: the downbeat first (which
            // may differ from the previous measure's port after a jump),
            // then every switch the measure itself carries.
            var candidates: [(tick: Int, port: Int)] = [(
                entry.tickOffset,
                port(atOriginalTick: measureBases[entry.measureIndex]),
            )]
            for entrySwitch in route.switches
                where entrySwitch.measureIndex == entry.measureIndex
            {
                candidates.append((
                    entry.tickOffset
                        + entrySwitch.position.ticks(division: division),
                    entrySwitch.port,
                ))
            }
            for candidate in candidates
                where candidate.port != current
                && (0 ... 127).contains(candidate.port)
            {
                events.append(TimedMidiEvent(
                    tick: candidate.tick,
                    event: .meta(.portChange(port: candidate.port)),
                ))
                current = candidate.port
            }
        }
        return events
    }

    /// Look only inside the first measure: only that measure's signature counts as
    /// the initial header value. A signature appearing later is a mid-piece change.
    static func firstTimeSignature(in staff: Staff) -> TimeSignature? {
        guard let firstMeasure = staff.measures.first else { return nil }
        for voice in firstMeasure.voices {
            for element in voice.elements {
                if case let .timeSignature(t) = element { return t }
            }
        }
        return nil
    }

    static func firstKeySignature(in staff: Staff) -> KeySignature? {
        guard let firstMeasure = staff.measures.first else { return nil }
        for voice in firstMeasure.voices {
            for element in voice.elements {
                if case let .keySignature(k) = element { return k }
            }
        }
        return nil
    }
}
