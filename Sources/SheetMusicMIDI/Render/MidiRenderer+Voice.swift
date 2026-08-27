import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation

extension MidiRenderer {
    /// Walk one voice across all measures producing notes +
    /// tempo/dynamic events. `plan` is the score-global unrolled
    /// playback order computed once by `render(score:)` — repeats,
    /// voltas, jumps and markers are already expanded into it.
    /// `<MeasureRepeat>` group replay still resolves per-staff (via
    /// `resolvedVoice`).
    static func renderVoice( // swiftlint:disable:this function_body_length cyclomatic_complexity
        voiceIndex: Int,
        staff: Staff,
        part: Part,
        route: PartChannelRoute,
        division: Int,
        plan: [PlaybackEntry],
        swingMap: SwingMap = .empty,
        systemElementsByMeasure: [[PositionedSystemElement]] = [],
    ) throws -> (events: [TimedMidiEvent], endTick: Int, lyricAnchors: [LyricMidiCodec.Anchor]) {
        let measureDurations = staff.measures.effectiveMeasureDurations()
        var events: [TimedMidiEvent] = []
        // Every non-rest chord's onset tick + its lyrics, in playback
        // order (repeats re-state lyrics on each take). Encoded into SMF
        // Lyric meta events by `LyricMidiCodec` at track assembly.
        var lyricAnchors: [LyricMidiCodec.Anchor] = []
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

        // Instrument-change channel switches, flattened against THIS
        // staff's measure bases so the two walkers cannot disagree.
        let channelSwitches = route.routeByOriginalTick(
            measureBases: originalMeasureBase, division: division,
        )
        /// Channel in force at `originalTick`. Linear scan: a part has
        /// at most a handful of changes, and the loop below queries it
        /// once per voice element.
        func channel(atOriginalTick tick: Int) -> Int {
            var result = route.defaultChannel
            for entry in channelSwitches {
                if entry.tick <= tick { result = entry.channel } else { break }
            }
            return result
        }

        // A tie chain must sound entirely on the channel that was in
        // force at its HEAD: `resolveTiedPitches` treats an
        // `.instrumentChange` like any other non-temporal element, so
        // a change CAN land between a tie's head and tail chord.
        // `emitNoteEvents` emits the note-on from the head element
        // and the note-off from the tail element — two independent
        // per-element channel resolutions — so without this, the
        // on/off pair could split across channels and leave a stuck
        // note on the old channel plus an orphan note-off on the new
        // one. Scoped to the whole voice walk (not reset per measure
        // or per plan entry) because a tie chain routinely spans a
        // bar line.
        var sustainedChannel: Int?

        // The unrolled `plan` is computed ONCE, score-globally, from
        // staff 0's measure count (see `render(score:)`), then applied
        // to every staff. A hand-built `Score` whose non-canonical
        // staff has FEWER measures than staff 0 would otherwise trap
        // here indexing `staff.measures[entry.measureIndex]` (directly
        // in `resolvedVoice`, and via `originalMeasureBase` below).
        // Well-formed parsed files are always aligned across staves, so
        // this guard is a no-op in practice; it exists purely to turn a
        // ragged staff into a silent truncation instead of a crash.
        var lastProcessedEntry: PlaybackEntry?
        for entry in plan {
            guard entry.measureIndex < staff.measures.count else { continue }
            lastProcessedEntry = entry
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

            // Guitar-bend chains resolve in a pre-pass over the whole voice:
            // a chain's suppression decisions depend on elements the walk has
            // not reached yet (does the next chord close the chain?), so they
            // cannot be taken element by element. Keyed by element index the
            // way `glissandoEndPitch` is resolved per element below.
            let bendChainSlots = guitarBendChains(
                voiceElements: effectiveVoice.elements,
            )

            // When a new iteration loops back to original measure 0 (e.g. volta
            // playback returning to the top of the score), re-emit timeSig + reset
            // tempo to default — matches MuseScore's exportmidi behavior where
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
                    case .staffText, .swing, .instrumentChange:
                        // Staff text doesn't render to MIDI; swing state
                        // is pre-collected into `swingMap`; instrument
                        // changes are resolved into `channelSwitches`
                        // before the walk — deliberately NOT emitted as
                        // a mid-stream program change (MuseScore puts
                        // every header at tick 0, exportmidi.cpp:247).
                        break
                    }
                }
            }
            let measureDuration = entry.measureIndex < measureDurations.count
                ? measureDurations[entry.measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            // Indices of `.chord` elements consumed by a preceding
            // two-note tremolo. The voice walker still advances
            // `localTick` past them so subsequent elements land
            // correctly, but emits no note events for the consumed
            // follower.
            var consumedByTremolo: Set<Int> = []
            for (elementIndex, element) in effectiveVoice.elements.enumerated() {
                var channel = channel(
                    atOriginalTick: localTick + originalTickDelta,
                )
                if case let .keySignature(k) = element { currentKey = k.concertKey }
                if consumedByTremolo.contains(elementIndex) {
                    consumedByTremolo.remove(elementIndex)
                    if case let .chord(c) = element {
                        localTick += c.duration
                            .resolved(in: measureDuration)
                            .ticks(division: division)
                    }
                    continue
                }
                // A chord continuing a tie (`tieBack != nil`) sounds on
                // whatever channel its head used, not the channel in
                // force at its own tick. A chord continuing the tie
                // FORWARD (`tieForward != nil`) publishes the channel
                // it just resolved to for the next link in the chain;
                // a chord with no forward tie ends any open chain.
                if case let .chord(chord) = element {
                    if chord.notes.contains(where: { $0.tieBack != nil }),
                       let sustained = sustainedChannel
                    {
                        channel = sustained
                    }
                    sustainedChannel = chord.notes.contains(where: { $0.tieForward != nil })
                        ? channel
                        : nil
                }
                // Tremolo branch: when a chord carries a `Tremolo`,
                // expand to per-stroke note events via the
                // `tremoloSegments` helper instead of the standard
                // chord-render path. For `.between` span, the
                // follower chord is also consumed.
                if case let .chord(chord) = element, chord.tremolo != nil {
                    try renderTremoloChord(
                        chord,
                        elementIndex: elementIndex,
                        voiceElements: effectiveVoice.elements,
                        measureDuration: measureDuration,
                        localTick: &localTick,
                        velocity: velocity,
                        consumedByTremolo: &consumedByTremolo,
                        channel: channel,
                        division: division,
                        events: &events,
                        hairpinRamps: hairpinRamps,
                        ottavaRanges: ottavaRanges,
                        originalTickDelta: originalTickDelta,
                    )
                    continue
                }
                renderVoiceElement(
                    element,
                    elementIndex: elementIndex,
                    bendChainSlots: bendChainSlots[elementIndex],
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
                    lyricAnchors: &lyricAnchors,
                    hairpinRamps: hairpinRamps,
                    ottavaRanges: ottavaRanges,
                    originalTickDelta: originalTickDelta,
                )
            }
        }

        let endTick: Int
        // Use the last IN-RANGE entry actually processed above (not
        // `plan.last`, which may reference a measure index this ragged
        // staff doesn't have — see the bounds guard at the top of the loop).
        if let last = lastProcessedEntry {
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
        return (events, endTick, lyricAnchors)
    }

    // swiftlint:disable:next function_parameter_count
    private static func renderVoiceElement( // swiftlint:disable:this function_body_length
        _ element: VoiceElement,
        elementIndex: Int,
        bendChainSlots: BendChainChordSlots?,
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
        lyricAnchors: inout [LyricMidiCodec.Anchor],
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
            // Anchor lyrics at the nominal (grid-aligned) onset so the
            // importer's quantized chord onsets match. Every non-rest
            // chord is recorded — even lyric-free ones — so melisma
            // continuations can be placed on the chords they cover.
            lyricAnchors.append(LyricMidiCodec.Anchor(tick: localTick, lyrics: chord.lyrics))
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
                bendChainSlots: bendChainSlots,
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
        case let .breath(breath):
            // Pauses are realized by shifting subsequent note onsets
            // forward at the constant tempo — exactly what MuseScore's
            // MIDI export does. Verified by dumping `mscore -o` output:
            // tempo stays unchanged across the pause; the next chord's
            // delta increases by `pause × bps × ppq` ticks.
            //
            // Mirrors mu::engraving::Breath::play() / MuseScore's
            // ExportMidi pauseMap → tick-advance lowering.
            if breath.pause > 0 {
                let extraTicks = Int(
                    (breath.pause * currentTempoBps * Double(division)).rounded(),
                )
                localTick += extraTicks
            }
        }
    }

    // The per-note emit used to live here as `emitNoteEvents`, but every
    // chord has routed through `renderChordWithGraces` since grace-note
    // support landed, leaving this copy unreachable. The live one is
    // `emitNoteEventsForGrace` in `MidiRenderer+Grace.swift`.

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
    /// to `defaultArticulationGateTime(for:)` so existing behavior is
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
    /// `defaultArticulationVelocityScale(for:)` so existing behavior
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
