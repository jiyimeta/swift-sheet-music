// swiftlint:disable file_length
import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Walk one voice across all measures producing notes + tempo/dynamic events.
    /// Honours `<startRepeat>`/`<endRepeat>` repeat markers (via `playbackPlan`)
    /// and `<MeasureRepeat>` group replay (via `resolvedVoice`). Volta-aware
    /// playback filtering is not yet implemented.
    static func renderVoice( // swiftlint:disable:this function_body_length cyclomatic_complexity
        voiceIndex: Int,
        staff: Staff,
        part: Part,
        channel: Int,
        division: Int,
        swingMap: SwingMap = .empty,
        systemElementsByMeasure: [[PositionedSystemElement]] = [],
    ) -> (events: [TimedMidiEvent], endTick: Int) {
        let measureDurations = staff.measures.effectiveMeasureDurations()
        let plan = playbackPlan(for: staff.measures, division: division)
        var events: [TimedMidiEvent] = []
        var velocity = effectiveVelocity(forDynamic: nil, instrument: part.instrument)
        // Tempo in beats-per-second; default is 2 bps (120 BPM = MuseScore's DEFAULT_TEMPO).
        var currentTempoBps = 2.0

        let hairpinRamps = HairpinRamps.collect(
            voiceIndex: voiceIndex,
            staff: staff,
            instrument: part.instrument,
            division: division,
        )
        let ottavaRanges = OttavaRanges.collect(
            voiceIndex: voiceIndex,
            staff: staff,
            division: division,
        )
        // Original-tick base for each measure index, used to map
        // playback ticks (which include unrolled repeats) back to
        // pre-repeat ticks for ramp lookup.
        var originalMeasureBase: [Int] = []
        do {
            var acc = 0
            for (idx, m) in staff.measures.enumerated() {
                originalMeasureBase.append(acc)
                let mDuration = idx < measureDurations.count
                    ? measureDurations[idx]
                    : Fraction(numerator: 4, denominator: 4)
                acc += measureTicks(
                    measure: m, division: division,
                    measureDuration: mDuration,
                )
            }
        }

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
                voiceIndex: voiceIndex,
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
                        thirtySecondsPerQuarter: 8,
                    )
                    events.append(TimedMidiEvent(tick: entry.tickOffset, event: .meta(timeSigMeta)))
                    events.append(TimedMidiEvent(tick: entry.tickOffset, event: .meta(.tempo(
                        microsecondsPerQuarter: defaultMicrosPerQuarter,
                    ))))
                    currentTempoBps = 2.0
                }
                // Reset dynamic state too: starting a fresh section means notes
                // play at the score's default (mf) velocity until a Dynamic re-asserts.
                velocity = effectiveVelocity(forDynamic: nil, instrument: part.instrument)
            }

            var localTick = entry.tickOffset
            var currentKey = firstKeySignature(in: staff)?.concertKey ?? 0
            let originalTickDelta = originalMeasureBase[entry.measureIndex] - entry.tickOffset
            // Inject lifted system elements at their measure-relative
            // positions before walking voice elements. Only voice 0
            // emits the meta events; non-zero voices skip the
            // injection so the same tempo / rehearsal doesn't fan out
            // across voices of the same staff (mirrors the previous
            // `voiceIndex == 0` guard).
            if voiceIndex == 0,
               entry.measureIndex < systemElementsByMeasure.count
            {
                for positioned in systemElementsByMeasure[entry.measureIndex] {
                    let tickAt = entry.tickOffset
                        + positioned.position.ticks(division: division)
                    switch positioned.element {
                    case let .tempo(tempo):
                        currentTempoBps = tempo.beatsPerSecond
                        events.append(TimedMidiEvent(
                            tick: tickAt,
                            event: .meta(.tempo(
                                microsecondsPerQuarter: tempo.microsecondsPerQuarter,
                            )),
                        ))
                    case let .rehearsalMark(rm):
                        if !rm.text.isEmpty {
                            events.append(TimedMidiEvent(
                                tick: tickAt,
                                event: .meta(.marker(rm.text)),
                            ))
                        }
                    case .staffText, .swing:
                        // Staff text doesn't render to MIDI; swing
                        // state is pre-collected into `swingMap`.
                        break
                    }
                }
            }
            let measureDuration = entry.measureIndex < measureDurations.count
                ? measureDurations[entry.measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            for (elementIndex, element) in effectiveVoice.elements.enumerated() {
                if case let .keySignature(k) = element { currentKey = k.concertKey }
                renderVoiceElement(
                    element,
                    elementIndex: elementIndex,
                    voiceElements: effectiveVoice.elements,
                    voiceTuplets: effectiveVoice.tuplets,
                    measures: staff.measures,
                    measureIndex: entry.measureIndex,
                    measureDuration: measureDuration,
                    currentKey: currentKey,
                    localTick: &localTick,
                    velocity: &velocity,
                    currentTempoBps: &currentTempoBps,
                    swingMap: swingMap,
                    voiceIndex: voiceIndex,
                    channel: channel,
                    instrument: part.instrument,
                    division: division,
                    events: &events,
                    hairpinRamps: hairpinRamps,
                    ottavaRanges: ottavaRanges,
                    originalTickDelta: originalTickDelta,
                )
            }
        }

        let endTick: Int
        if let last = plan.last {
            let lastDuration = last.measureIndex < measureDurations.count
                ? measureDurations[last.measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            endTick = last.tickOffset + measureTicks(
                measure: staff.measures[last.measureIndex],
                division: division,
                measureDuration: lastDuration,
            )
        } else {
            endTick = 0
        }
        return (events, endTick)
    }

    // swiftlint:disable:next function_parameter_count
    private static func renderVoiceElement( // swiftlint:disable:this function_body_length
        _ element: VoiceElement,
        elementIndex: Int,
        voiceElements: [VoiceElement],
        voiceTuplets: [Tuplet],
        measures: [Measure],
        measureIndex: Int,
        measureDuration: Fraction,
        currentKey: Int,
        localTick: inout Int,
        velocity: inout Int,
        currentTempoBps: inout Double,
        swingMap: SwingMap,
        voiceIndex: Int,
        channel: Int,
        instrument: Instrument,
        division: Int,
        events: inout [TimedMidiEvent],
        hairpinRamps: [HairpinRamp],
        ottavaRanges: [OttavaRange],
        originalTickDelta: Int,
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
                    thirtySecondsPerQuarter: 8,
                )
                events.append(TimedMidiEvent(tick: localTick, event: .meta(meta)))
            }
        case .clef, .barLine, .spanner, .measureRepeat, .harmony:
            return
        case let .locationShift(delta):
            // Voice cursor shift: applies the location's fractional
            // delta to the running tick so subsequent dynamic /
            // marker events land at the correct beat. Mirrors
            // `LayoutEngine`'s placement-side handling.
            localTick += delta.ticks(division: division)
        case let .dynamic(dynamic):
            velocity = effectiveVelocity(forDynamic: dynamic, instrument: instrument)
        case let .chord(chord) where chord.notes.isEmpty:
            // Rest: advance the tick cursor, emit no note events.
            localTick += chord.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
        case let .chord(chord):
            let glissandoEndPitch = chord.notes.contains(where: { $0.glissando != nil })
                ? MidiRenderer.glissandoEndPitch(
                    voiceElements: voiceElements,
                    afterElementIndex: elementIndex,
                    measures: measures,
                    measureIndex: measureIndex,
                    voiceIndex: voiceIndex,
                )
                : nil
            // Apply swing: shift the onset and adjust the played
            // duration per the active swing state. `localTick` itself
            // continues to advance by the chord's nominal duration so
            // the swing grid stays aligned to the bar.
            let chordTicks = chord.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
            let adjust = swingAdjustment(
                startTick: localTick,
                chordTicks: chordTicks,
                prevChordTicks: previousChordTicks(
                    in: voiceElements,
                    before: elementIndex,
                    measureDuration: measureDuration,
                    division: division,
                ),
                nextChordTicks: nextChordTicks(
                    in: voiceElements,
                    after: elementIndex,
                    measureDuration: measureDuration,
                    division: division,
                ),
                isInTuplet: isChordInTuplet(
                    elementIndex: elementIndex,
                    voiceTuplets: voiceTuplets,
                ),
                state: swingMap.state(atTick: localTick + originalTickDelta),
            )
            // Hairpin influence is scoped to the chord onset; the
            // running `velocity` is untouched, so the next .dynamic
            // resets it normally for post-ramp playback. Look up the
            // ramp at the swing-adjusted onset so the velocity tracks
            // the audible attack rather than the nominal grid.
            let onsetOriginalTick = (localTick + adjust.onsetShift) + originalTickDelta
            let chordVelocity =
                HairpinRamps.active(in: hairpinRamps, at: onsetOriginalTick)
                .map { HairpinRamps.interpolate(ramp: $0, atOriginalTick: onsetOriginalTick) }
                ?? velocity
            let ottavaShift = OttavaRanges.semitones(
                in: ottavaRanges, at: onsetOriginalTick,
            )
            renderChordWithGraces(
                chord,
                tick: localTick + adjust.onsetShift,
                velocity: chordVelocity,
                channel: channel,
                instrument: instrument,
                tempoBps: currentTempoBps,
                division: division,
                glissandoEndPitch: glissandoEndPitch,
                currentKey: currentKey,
                events: &events,
                playedTicksOverride: adjust == .none
                    ? nil
                    : max(1, chordTicks + adjust.lengthDelta),
                pitchShift: ottavaShift,
            )
            localTick += chordTicks
        case .fermata:
            // Held-duration is realised by per-staff tempo bookends
            // emitted in `MidiRenderer.renderTrack` from
            // `FermataRanges`. The voice walk does not need to
            // touch tempo or tick state here.
            break
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
        events: inout [TimedMidiEvent],
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

    /// Per-chord gateTime lookup. Filters `chord.articulations` to the
    /// in-scope duration-shaping kinds (staccato / staccatissimo /
    /// tenuto), looks each up in the instrument preset table, and
    /// returns the **minimum** gateTime% among the candidates (matches
    /// MuseScore's `MidiArticulation::aggregateOf` — most-shortening
    /// wins). When no in-scope articulation is present, falls through
    /// to `defaultArticulationGateTime(for:)` so existing behaviour is
    /// preserved. C++:
    ///   engraving/compat/midi/compatmidirender.cpp
    ///   `CompatMidiRender::collectMeasureEvents` — `articulationGateTime`.
    static func effectiveGateTime(for chord: Chord, instrument: Instrument) -> Int {
        let gates = chord.articulations.compactMap { art -> Int? in
            let presetName: String
            let hardcodedDefault: Int
            switch art.kind {
            case .staccato: presetName = "staccato"; hardcodedDefault = 50
            case .staccatissimo: presetName = "staccatissimo"; hardcodedDefault = 33
            case .tenuto: presetName = "tenuto"; hardcodedDefault = 100
            case .accentStaccato, .marcatoStaccato:
                presetName = "staccato"; hardcodedDefault = 50
            case .accent, .marcato, .unknown:
                return nil
            }
            return instrument.articulations
                .first(where: { $0.name == presetName })?
                .gateTime ?? hardcodedDefault
        }
        if let minimum = gates.min() {
            return minimum
        }
        return defaultArticulationGateTime(for: instrument)
    }

    /// Per-chord velocity-scale lookup. Filters `chord.articulations`
    /// to the in-scope velocity-shaping kinds (accent / marcato /
    /// accentStaccato / marcatoStaccato), looks each up in the
    /// instrument preset table, and returns the **maximum** velocity %
    /// among the candidates (matches MuseScore's
    /// `MidiArticulation::aggregateOf` — loudest wins). When no
    /// in-scope articulation is present, falls through to
    /// `defaultArticulationVelocityScale(for:)` so existing behaviour
    /// is preserved. C++:
    ///   engraving/compat/midi/compatmidirender.cpp
    ///   `CompatMidiRender::collectMeasureEvents` — articulation velocity.
    static func effectiveVelocityScale(for chord: Chord, instrument: Instrument) -> Int {
        let scales = chord.articulations.compactMap { art -> Int? in
            let presetName: String
            let hardcodedDefault: Int
            switch art.kind {
            case .accent, .accentStaccato:
                presetName = "accent"; hardcodedDefault = 120
            case .marcato, .marcatoStaccato:
                presetName = "marcato"; hardcodedDefault = 120
            case .staccato, .staccatissimo, .tenuto, .unknown:
                return nil
            }
            return instrument.articulations
                .first(where: { $0.name == presetName })?
                .velocity ?? hardcodedDefault
        }
        if let maximum = scales.max() {
            return maximum
        }
        return defaultArticulationVelocityScale(for: instrument)
    }

    /// Apply per-chord velocity scaling on top of the running voice
    /// velocity. `baseVelocity` already has the **default** articulation
    /// scale baked in (set by `effectiveVelocity` at voice setup /
    /// Dynamic events); the modifier swaps that default scale for the
    /// chord-effective scale via `base * eff / def`. Returns
    /// `baseVelocity` unchanged when the chord has no velocity-shaping
    /// articulation, so existing playback for unarticulated chords is
    /// bit-identical.
    static func adjustVelocityForChord(
        baseVelocity: Int,
        chord: Chord,
        instrument: Instrument,
    ) -> Int {
        let defaultScale = defaultArticulationVelocityScale(for: instrument)
        let effectiveScale = effectiveVelocityScale(for: chord, instrument: instrument)
        if defaultScale == effectiveScale { return baseVelocity }
        return min(127, max(1, baseVelocity * effectiveScale / defaultScale))
    }
}
