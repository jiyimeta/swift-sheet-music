import Foundation

/// Renders a `Score` into a `MidiFile`. Scope is growing test-by-test from the
/// midi01 vertical slice. Currently handles: multi-staff (one MIDI track per
/// staff, channel = staff index), multi-voice within a staff (each voice
/// concurrently shares the channel), tempo and dynamic markers, full-measure
/// rests, dotted durations, plus skip-only handling for Clef / BarLine /
/// Spanner / MeasureRepeat (these don't produce MIDI events yet).
public enum MidiRenderer {
    /// Default base velocity for "mf" when no Dynamic has been seen.
    private static let defaultDynamicVelocity = 80

    /// Default tempo if the score has no Tempo markers (120 BPM = 500000 µs/quarter).
    private static let defaultMicrosPerQuarter = 500_000

    /// Render the given `Score` into a `MidiFile` ready for serialisation.
    public static func render(score: Score) throws -> MidiFile {
        var tracks: [MidiTrack] = []

        for (staffIndex, staff) in score.staves.enumerated() {
            let part = try part(at: staffIndex, in: score)
            let channel = part.instrument.channel.midiChannel ?? staffIndex
            let port = part.instrument.channel.midiPort ?? 0
            let track = renderTrack(
                staff: staff,
                part: part,
                channel: channel,
                port: port,
                isFirstTrack: staffIndex == 0,
                division: score.division
            )
            tracks.append(track)
        }

        return MidiFile(division: score.division, format: 1, tracks: tracks)
    }

    private static func renderTrack(
        staff: StaffContent,
        part: Part,
        channel: Int,
        port: Int,
        isFirstTrack: Bool,
        division: Int
    ) -> MidiTrack {
        var events: [TimedMidiEvent] = headerEvents(
            staff: staff, part: part, channel: channel, port: port, isFirstTrack: isFirstTrack
        )

        var endTickPerVoice: [Int] = []
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0..<voiceCount {
            let (voiceEvents, endTick) = renderVoice(
                voiceIndex: voiceIndex,
                staff: staff,
                part: part,
                channel: channel,
                division: division
            )
            events.append(contentsOf: voiceEvents)
            endTickPerVoice.append(endTick)
        }

        // EoT lands one tick after the last produced event (MuseScore convention).
        // For tracks with notes this is final-noteOff + 1; for empty tracks it's 1.
        let lastEventTick = events.map(\.tick).max() ?? 0
        events.append(TimedMidiEvent(tick: lastEventTick + 1, event: .endOfTrack))
        _ = endTickPerVoice

        // Stable sort by tick — preserves header insertion order at tick 0
        // and keeps voice-0 events ahead of voice-1 events at the same tick.
        let sorted = events.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)

        return MidiTrack(events: sorted)
    }

    private static func headerEvents(
        staff: StaffContent,
        part: Part,
        channel: Int,
        port: Int,
        isFirstTrack: Bool
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
                thirtySecondsPerQuarter: 8
            ))))
        }

        let initialKey = firstKeySignature(in: staff) ?? KeySignature(concertKey: 0)
        events.append(TimedMidiEvent(tick: 0, event: .meta(.keySignature(
            sharpsFlats: initialKey.concertKey, isMinor: false
        ))))

        if isFirstTrack {
            events.append(TimedMidiEvent(tick: 0, event: .meta(.tempo(
                microsecondsPerQuarter: defaultMicrosPerQuarter
            ))))
        }

        func cc(_ controller: Int, _ value: Int) {
            let event = MidiEvent.controlChange(channel: channel, controller: controller, value: value)
            events.append(TimedMidiEvent(tick: 0, event: event))
        }

        // Reset all controllers (always); RPN block to set pitch-bend range = 12 semitones
        // is suppressed on channel 9 (drum channel) — matches MuseScore's exportmidi.cpp.
        cc(121, 0)
        if channel != 9 {
            cc(100, 0)
            cc(101, 0)
            cc(6, 12)
            cc(100, 127)
            cc(101, 127)
        }

        let ch = part.instrument.channel
        events.append(TimedMidiEvent(tick: 0, event: .programChange(channel: channel, program: ch.program)))
        cc(7, ch.volume)
        cc(10, ch.pan)
        cc(91, ch.reverb)
        cc(93, ch.chorus)

        // Port change meta only when port fits in a single SMF byte (0..127).
        if (0...127).contains(port) {
            events.append(TimedMidiEvent(tick: 0, event: .meta(.portChange(port: port))))
        }
        return events
    }

    /// Walk one voice across all measures producing notes + tempo/dynamic events.
    /// Honours simple `<startRepeat>` / `<endRepeat>` markers by replaying the
    /// repeated measure span (without Volta-aware filtering, which is a future
    /// extension).
    /// Returns the produced events and the final tick.
    private static func renderVoice(
        voiceIndex: Int,
        staff: StaffContent,
        part: Part,
        channel: Int,
        division: Int
    ) -> (events: [TimedMidiEvent], endTick: Int) {
        let plan = playbackPlan(for: staff.measures, division: division)
        var events: [TimedMidiEvent] = []
        var velocity = effectiveVelocity(forDynamic: nil, instrument: part.instrument)

        for entry in plan {
            let measure = staff.measures[entry.measureIndex]
            let baseTick = entry.tickOffset
            guard voiceIndex < measure.voices.count else { continue }
            let voice = measure.voices[voiceIndex]

            // If this measure is a measure-repeat marker, splice in the previous
            // measure's voice instead. (MuseScore plays the prior measure's content
            // again, keeping the new measure's tick offset.)
            let effectiveVoice = resolvedVoice(
                voice: voice,
                measureIndex: entry.measureIndex,
                staff: staff,
                voiceIndex: voiceIndex
            )

            var localTick = baseTick
            for element in effectiveVoice.elements {
                switch element {
                case let .keySignature(key):
                    // Initial key sig is emitted by the header pass; emit mid-piece
                    // changes here.
                    if localTick > 0 {
                        let meta = MetaEvent.keySignature(sharpsFlats: key.concertKey, isMinor: false)
                        events.append(TimedMidiEvent(tick: localTick, event: .meta(meta)))
                    }
                case let .timeSignature(t):
                    if localTick > 0 {
                        let meta = MetaEvent.timeSignature(
                            numerator: t.numerator,
                            denominator: t.denominator,
                            clocksPerClick: 24,
                            thirtySecondsPerQuarter: 8
                        )
                        events.append(TimedMidiEvent(tick: localTick, event: .meta(meta)))
                    }
                case .clef, .barLine, .spanner, .measureRepeat:
                    continue
                case let .tempo(tempo):
                    if voiceIndex == 0 {
                        events.append(TimedMidiEvent(tick: localTick, event: .meta(.tempo(
                            microsecondsPerQuarter: tempo.microsecondsPerQuarter
                        ))))
                    }
                case let .dynamic(dynamic):
                    velocity = effectiveVelocity(forDynamic: dynamic, instrument: part.instrument)
                case let .rest(rest):
                    localTick += rest.duration.ticks(division: division)
                case let .chord(chord):
                    let durationTicks = chord.duration.ticks(division: division)
                    let gate = defaultArticulationGateTime(for: part.instrument)
                    let gatedTicks = durationTicks * gate / 100
                    let offTick = localTick + gatedTicks - 1
                    for note in chord.notes {
                        let on = MidiEvent.noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
                        let off = MidiEvent.noteOff(channel: channel, pitch: note.pitch, velocity: 0)
                        events.append(TimedMidiEvent(tick: localTick, event: on))
                        events.append(TimedMidiEvent(tick: offTick, event: off))
                    }
                    localTick += durationTicks
                }
            }
        }

        let endTick: Int
        if let last = plan.last {
            endTick = last.tickOffset + measureTicks(measure: staff.measures[last.measureIndex], division: division)
        } else {
            endTick = 0
        }
        return (events, endTick)
    }

    /// If `voice` contains a `MeasureRepeat`, return a synthetic voice that
    /// replays the most recent non-repeat measure's notes/rests at this
    /// measure's tick offset. Metadata (KeySig/TimeSig/Clef/etc.) is stripped
    /// from the replay. Chained repeats fall through to the prior real measure.
    private static func resolvedVoice(
        voice: Voice,
        measureIndex: Int,
        staff: StaffContent,
        voiceIndex: Int
    ) -> Voice {
        guard voice.elements.contains(where: {
            if case .measureRepeat = $0 { return true } else { return false }
        }) else {
            return voice
        }
        var source = measureIndex - 1
        while source >= 0 {
            guard voiceIndex < staff.measures[source].voices.count else {
                source -= 1; continue
            }
            let sourceVoice = staff.measures[source].voices[voiceIndex]
            let isRepeat = sourceVoice.elements.contains {
                if case .measureRepeat = $0 { return true } else { return false }
            }
            if isRepeat {
                source -= 1
                continue
            }
            let stripped = sourceVoice.elements.filter {
                switch $0 {
                case .chord, .rest, .dynamic: return true
                default: return false
                }
            }
            return Voice(elements: stripped)
        }
        return Voice(elements: [])
    }

    /// One measure-play in the unrolled playback order: `(originalMeasureIndex, tickOffsetForThisPlay)`.
    private struct PlaybackEntry {
        var measureIndex: Int
        var tickOffset: Int
    }

    /// Build the full unrolled playback sequence from `<startRepeat>`/`<endRepeat>` markers.
    /// Assumes `endRepeatCount` ≥ 2 means "play this segment that many times in total".
    /// Without an explicit `<startRepeat>`, the segment is taken from measure 0
    /// (or from the previous endRepeat boundary).
    private static func playbackPlan(for measures: [Measure], division: Int) -> [PlaybackEntry] {
        var plan: [PlaybackEntry] = []
        var tick = 0
        var segmentStart = 0
        var index = 0

        while index < measures.count {
            let measure = measures[index]
            if measure.startRepeat {
                segmentStart = index
            }

            plan.append(PlaybackEntry(measureIndex: index, tickOffset: tick))
            tick += measureTicks(measure: measure, division: division)

            if let count = measure.endRepeatCount, count > 1 {
                // Replay [segmentStart…index] (count - 1) more times.
                for _ in 1..<count {
                    for j in segmentStart...index {
                        plan.append(PlaybackEntry(measureIndex: j, tickOffset: tick))
                        tick += measureTicks(measure: measures[j], division: division)
                    }
                }
                segmentStart = index + 1   // next implicit segment starts after the closed repeat
            }
            index += 1
        }
        return plan
    }

    /// Reference duration of a measure in ticks. Uses voice 0; falls back to whatever
    /// time signature is currently in effect (4/4 default if none).
    private static func measureTicks(measure: Measure, division: Int) -> Int {
        guard let voice = measure.voices.first else { return 4 * division }
        var ticks = 0
        for element in voice.elements {
            switch element {
            case let .chord(chord): ticks += chord.duration.ticks(division: division)
            case let .rest(rest):   ticks += rest.duration.ticks(division: division)
            case let .measureRepeat(rep): ticks += rep.duration.ticks(division: division)
            default: continue
            }
        }
        return ticks
    }

    private static func effectiveVelocity(forDynamic dynamic: Dynamic?, instrument: Instrument) -> Int {
        let base = dynamic?.velocity ?? defaultDynamicVelocity
        let scale = defaultArticulationVelocityScale(for: instrument)
        return min(127, max(1, base * scale / 100))
    }

    /// Pick the part for the given staff index. mscx lists parts and top-level
    /// staff-content blocks in matching document order, so a 1:1 index mapping
    /// is correct for the tests we currently target (each part has one staff).
    private static func part(at staffIndex: Int, in score: Score) throws -> Part {
        guard staffIndex < score.parts.count else {
            // Fall back to first part if the indexing is off (e.g. piano with two
            // staves per part). Better to render with the wrong instrument than
            // to refuse to render at all.
            if let part = score.parts.first {
                return part
            }
            throw MuseScoreParserError.malformedScore(reason: "Score has no parts")
        }
        return score.parts[staffIndex]
    }

    /// Look only inside the first measure: only that measure's signature counts as
    /// the initial header value. A signature appearing later is a mid-piece change
    /// (rendered as a tick > 0 meta event by a later pass).
    private static func firstTimeSignature(in staff: StaffContent) -> TimeSignature? {
        guard let firstMeasure = staff.measures.first else { return nil }
        for voice in firstMeasure.voices {
            for element in voice.elements {
                if case let .timeSignature(t) = element { return t }
            }
        }
        return nil
    }

    private static func firstKeySignature(in staff: StaffContent) -> KeySignature? {
        guard let firstMeasure = staff.measures.first else { return nil }
        for voice in firstMeasure.voices {
            for element in voice.elements {
                if case let .keySignature(k) = element { return k }
            }
        }
        return nil
    }

    private static func defaultArticulationVelocityScale(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.velocity ?? 100
    }

    private static func defaultArticulationGateTime(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.gateTime ?? 100
    }
}
