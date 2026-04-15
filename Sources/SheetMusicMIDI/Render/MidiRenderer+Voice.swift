import Foundation
import SheetMusicCore

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
            // Splice in the source measure's notes if this measure is a
            // measure-repeat. Returns nil only when neither the current
            // measure nor any source measure has this voice — silent skip.
            // We do NOT bail early on `voiceIndex >= measure.voices.count`:
            // a measure that only has voice 0 may still need voice 1 played
            // when it's a repeat-group whose source has voice 1.
            guard let effectiveVoice = MidiRenderer.resolvedVoice(
                measureIndex: entry.measureIndex,
                staff: staff,
                voiceIndex: voiceIndex
            ) else { continue }

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
        case .fermata:
            // Fermatas are a display-only annotation in our current Score;
            // they don't affect MIDI output (MuseScore performs them via
            // tempomap stretching — not replicated here).
            break
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
                emitNoteEvents(
                    note: note, channel: channel, velocity: velocity,
                    onTick: onTick, offTick: offTick, events: &events
                )
            }
        } else {
            let gate = defaultArticulationGateTime(for: instrument)
            let gatedTicks = durationTicks * gate / 100
            let offTick = tick + gatedTicks - 1
            for note in chord.notes {
                emitNoteEvents(
                    note: note, channel: channel, velocity: velocity,
                    onTick: tick, offTick: offTick, events: &events
                )
            }
        }
    }

    /// Emit note-on/off for a single note, respecting tie flags. For a tied chain
    /// we want ONE combined event pair:
    ///   - A note with `tieBack` set must not re-trigger: its note-on is suppressed
    ///     because the preceding chord's note-on is still sounding.
    ///   - A note with `tieForward` set must not release: its note-off is suppressed
    ///     because the sound continues into the following chord.
    /// Mirrors MuseScore's `Note::playTicksFraction()` which reports the full tied
    /// span as the single sounding event.
    private static func emitNoteEvents(
        note: Note,
        channel: Int,
        velocity: Int,
        onTick: Int,
        offTick: Int,
        events: inout [TimedMidiEvent]
    ) {
        if note.tieBack == nil {
            let on = MidiEvent.noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
            events.append(TimedMidiEvent(tick: onTick, event: on))
        }
        if note.tieForward == nil {
            let off = MidiEvent.noteOff(channel: channel, pitch: note.pitch, velocity: 0)
            events.append(TimedMidiEvent(tick: offTick, event: off))
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
