import Foundation

extension MidiRenderer {
    /// Walk one voice across all measures producing notes + tempo/dynamic events.
    /// Honours `<startRepeat>`/`<endRepeat>` repeat markers (via `playbackPlan`)
    /// and `<MeasureRepeat>` group replay (via `resolvedVoice`). Volta-aware
    /// playback filtering is not yet implemented.
    static func renderVoice(
        voiceIndex: Int,
        staff: StaffContent,
        part: Part,
        channel: Int,
        division: Int
    ) -> (events: [TimedMidiEvent], endTick: Int) {
        let plan = playbackPlan(for: staff.measures, division: division)
        var events: [TimedMidiEvent] = []
        var velocity = effectiveVelocity(forDynamic: nil, instrument: part.instrument)
        // Tempo in beats-per-second; default is 2 bps (120 BPM = MuseScore's DEFAULT_TEMPO).
        var currentTempoBps = 2.0

        for entry in plan {
            let measure = staff.measures[entry.measureIndex]
            guard voiceIndex < measure.voices.count else { continue }
            let voice = measure.voices[voiceIndex]

            // Splice in the source measure's notes if this measure is a measure-repeat.
            let effectiveVoice = resolvedVoice(
                voice: voice,
                measureIndex: entry.measureIndex,
                staff: staff,
                voiceIndex: voiceIndex
            )

            // When a new iteration loops back to original measure 0 (e.g. volta
            // playback returning to the top of the score), re-emit timeSig + reset
            // tempo to default — matches MuseScore's exportmidi behaviour where
            // each RepeatSegment whose first measure starts at tick 0 also emits
            // those meta events at its utick start. Loops that repeat a measure
            // mid-score (single-measure repeat) keep their existing state.
            let isFreshSectionStart =
                entry.isIterationStart && entry.measureIndex == 0 && entry.tickOffset > 0
            if isFreshSectionStart {
                if voiceIndex == 0 {
                    let timeSig = firstTimeSignature(in: staff) ?? TimeSignature(numerator: 4, denominator: 4)
                    let timeSigMeta = MetaEvent.timeSignature(
                        numerator: timeSig.numerator,
                        denominator: timeSig.denominator,
                        clocksPerClick: 24,
                        thirtySecondsPerQuarter: 8
                    )
                    events.append(TimedMidiEvent(tick: entry.tickOffset, event: .meta(timeSigMeta)))
                    events.append(TimedMidiEvent(tick: entry.tickOffset, event: .meta(.tempo(
                        microsecondsPerQuarter: defaultMicrosPerQuarter
                    ))))
                    currentTempoBps = 2.0
                }
                // Reset dynamic state too: starting a fresh section means notes
                // play at the score's default (mf) velocity until a Dynamic re-asserts.
                velocity = effectiveVelocity(forDynamic: nil, instrument: part.instrument)
            }

            var localTick = entry.tickOffset
            for element in effectiveVoice.elements {
                renderVoiceElement(
                    element,
                    localTick: &localTick,
                    velocity: &velocity,
                    currentTempoBps: &currentTempoBps,
                    voiceIndex: voiceIndex,
                    channel: channel,
                    instrument: part.instrument,
                    division: division,
                    events: &events
                )
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

    // swiftlint:disable:next function_parameter_count
    private static func renderVoiceElement(
        _ element: VoiceElement,
        localTick: inout Int,
        velocity: inout Int,
        currentTempoBps: inout Double,
        voiceIndex: Int,
        channel: Int,
        instrument: Instrument,
        division: Int,
        events: inout [TimedMidiEvent]
    ) {
        switch element {
        case let .keySignature(key):
            // Initial key sig is emitted by the header pass; only emit mid-piece changes.
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
            return
        case let .tempo(tempo):
            currentTempoBps = tempo.beatsPerSecond
            if voiceIndex == 0 {
                events.append(TimedMidiEvent(tick: localTick, event: .meta(.tempo(
                    microsecondsPerQuarter: tempo.microsecondsPerQuarter
                ))))
            }
        case let .dynamic(dynamic):
            velocity = effectiveVelocity(forDynamic: dynamic, instrument: instrument)
        case let .rest(rest):
            localTick += rest.duration.ticks(division: division)
        case let .chord(chord):
            renderChord(
                chord,
                tick: localTick,
                velocity: velocity,
                channel: channel,
                instrument: instrument,
                tempoBps: currentTempoBps,
                division: division,
                events: &events
            )
            localTick += chord.duration.ticks(division: division)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func renderChord(
        _ chord: Chord,
        tick: Int,
        velocity: Int,
        channel: Int,
        instrument: Instrument,
        tempoBps: Double,
        division: Int,
        events: inout [TimedMidiEvent]
    ) {
        let durationTicks = chord.duration.ticks(division: division)
        if let arpeggio = chord.arpeggio {
            let pairs = arpeggioNoteEvents(
                noteCount: chord.notes.count,
                chordTicks: durationTicks,
                stretch: arpeggio.timeStretch,
                tempoBps: tempoBps
            )
            let order = arpeggio.isAscending
                ? Array(0..<chord.notes.count)
                : Array((0..<chord.notes.count).reversed())
            for (i, noteIndex) in order.enumerated() {
                let note = chord.notes[noteIndex]
                let onTick = tick + pairs[i].onOffset
                let offTick = tick + pairs[i].offOffset
                let on = MidiEvent.noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
                let off = MidiEvent.noteOff(channel: channel, pitch: note.pitch, velocity: 0)
                events.append(TimedMidiEvent(tick: onTick, event: on))
                events.append(TimedMidiEvent(tick: offTick, event: off))
            }
        } else {
            let gate = defaultArticulationGateTime(for: instrument)
            let gatedTicks = durationTicks * gate / 100
            let offTick = tick + gatedTicks - 1
            for note in chord.notes {
                let on = MidiEvent.noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
                let off = MidiEvent.noteOff(channel: channel, pitch: note.pitch, velocity: 0)
                events.append(TimedMidiEvent(tick: tick, event: on))
                events.append(TimedMidiEvent(tick: offTick, event: off))
            }
        }
    }

    static func effectiveVelocity(forDynamic dynamic: Dynamic?, instrument: Instrument) -> Int {
        let base = dynamic?.velocity ?? defaultDynamicVelocity
        let scale = defaultArticulationVelocityScale(for: instrument)
        return min(127, max(1, base * scale / 100))
    }

    static func defaultArticulationVelocityScale(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.velocity ?? 100
    }

    static func defaultArticulationGateTime(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.gateTime ?? 100
    }
}
