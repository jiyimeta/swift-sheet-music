import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation

extension MidiRenderer {
    /// Walk one voice across all measures producing notes +
    /// tempo/dynamic events. `plan` is the score-global unrolled
    /// playback order computed once by `render(score:)` — repeats,
    /// voltas, jumps and markers are already expanded into it.
    /// `<MeasureRepeat>` group replay still resolves per-staff (via
    /// `resolvedVoice`). `emitsTempoEvents` is set for the first track's voice 0, which carries the score's tempo
    /// map as MuseScore's export does (`importexport/midi/internal/midiexport/exportmidi.cpp:177-204`); `bookends`
    /// are that track's fermata bookends, which decide with it whether a jump's target needs its tempo re-stated.
    /// `staffIndex` is `staff`'s place in `part.staves`: the voice plays every dynamic of the part that reaches it.
    static func renderVoice( // swiftlint:disable:this function_body_length cyclomatic_complexity
        voiceIndex: Int,
        staffIndex: Int = 0,
        staff: Staff,
        part: Part,
        route: PartChannelRoute,
        division: Int,
        plan: [PlaybackEntry],
        swingMap: SwingMap = .empty,
        systemElementsByMeasure: [[PositionedSystemElement]] = [],
        tempoMap: ResolvedTempoMap,
        emitsTempoEvents: Bool = false,
        bookends: BookendTempoTrack = BookendTempoTrack(),
    ) throws -> (events: [TimedMidiEvent], endTick: Int, lyricAnchors: [LyricMidiCodec.Anchor]) {
        let measureDurations = staff.measures.effectiveMeasureDurations()
        // Swing reads a beat position out of a tick, so its grid has to be measured from the BAR rather than from
        // the score's tick 0 — see `anacrusisOffsets()` for the pickup that made this a bug rather than a nicety.
        let anacrusisOffsets = staff.measures.anacrusisOffsets()
        var events: [TimedMidiEvent] = []
        // Every non-rest chord's onset tick + its lyrics, in playback
        // order (repeats re-state lyrics on each take). Encoded into SMF
        // Lyric meta events by `LyricMidiCodec` at track assembly.
        var lyricAnchors: [LyricMidiCodec.Anchor] = []
        // Tempo in beats-per-second; default is 2 bps (120 BPM = MuseScore's DEFAULT_TEMPO).
        var currentTempoBps = 2.0
        // The last tempo meta this walk wrote on the first track, carried from plan entry to plan entry.
        var tempoSequence = TempoSequence()

        let allDynamics = HairpinRamps.timeline(
            staffIndex: staffIndex,
            voiceIndex: voiceIndex,
            staves: Array(part.staves),
            instrument: part.instrument,
            division: division,
            tempoMap: tempoMap,
        )
        let ottavaRanges = OttavaRanges.collect(
            staff: staff,
            division: division,
            tempoMap: tempoMap,
        )
        let capoPoints = CapoRanges.collect(staff: staff, division: division, tempoMap: tempoMap)
        // Original-tick base for each measure index, used to map
        // playback ticks (which include unrolled repeats) back to
        // pre-repeat ticks for ramp lookup.
        var originalMeasureBase: [Int] = []
        var originalScoreEnd = 0
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
                    measureIndex: idx, tempoMap: tempoMap,
                )
            }
            originalScoreEnd = acc
        }

        // Instrument-change channel switches, flattened against THIS
        // staff's measure bases so the two walkers cannot disagree.
        let channelSwitches = route.routeByOriginalTick(
            measureBases: originalMeasureBase, division: division,
        )
        /// Channel in force at `originalTick`. Linear scan: a part has
        /// at most a handful of changes, and the loop below queries it
        /// once per voice element. (`PartChannelRoute.channel(atOriginalTick:in:)` is the same scan.)
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
        // What each open tie chain's gate has dropped so far, by sounding pitch (`tieGatedOff`). Voice-wide for the
        // same reason as the channel.
        var tieGateDebt: [Int: Int] = [:]
        // The capo an open tie chain's head sounded through (`.some(nil)` for none), for the same reason.
        var sustainedCapo: CapoPoint??

        // The timeline the run being played hears (`DynamicsTimeline.pass(startingAt:carrying:)`): all of it until a
        // repeat or a jump starts a new run.
        var dynamics = allDynamics

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
            let previous = lastProcessedEntry
            let jumped = previous.map { $0.measureIndex + 1 != entry.measureIndex } ?? false
            lastProcessedEntry = entry
            if jumped, let previous {
                // MuseScore 4 reads a note's level from a map built in playback order (`PlaybackContext::update`,
                // `engraving/playback/playbackcontext.cpp:309-347`): a jump lands with the level in force where it
                // left, and the new run hears only the ramps that reach it.
                let sourceEnd = previous.measureIndex + 1 < originalMeasureBase.count
                    ? originalMeasureBase[previous.measureIndex + 1]
                    : originalScoreEnd
                let carried = dynamics.carriedVelocity(atOriginalTick: sourceEnd - 1)
                dynamics = allDynamics.pass(startingAt: originalMeasureBase[entry.measureIndex], carrying: carried)
            }
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
                voiceElements: effectiveVoice.elements.values,
            )

            // When a new iteration loops back to original measure 0 (e.g. volta playback returning to the top of the
            // score), re-emit timeSig + reset tempo to default (the dynamic level carries — see the jump above) —
            // matches MuseScore's exportmidi behavior where each RepeatSegment whose first measure starts at tick 0
            // also emits those meta events at its utick start. Loops that repeat a measure mid-score (single-measure
            // repeat) keep their existing state.
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
                    tempoSequence = TempoSequence(tick: entry.tickOffset)
                }
            }

            var localTick = entry.tickOffset
            var pauseTicksInMeasure = 0
            var currentKey = firstKeySignature(in: staff)?.concertKey ?? 0
            let originalTickDelta = originalMeasureBase[entry.measureIndex] - entry.tickOffset
            // Tempo metas come from the resolved tempo map, written once on track 0 / voice 0
            // (`emitsTempoEvents`; MuseScore writes all tempo into the first track, exportmidi.cpp:55).
            // Rehearsal marks still come from the lifted system elements below, at their
            // measure-relative positions; only voice 0 emits them so they don't fan out across voices.
            if emitsTempoEvents {
                events += tempoEvents(
                    for: entry, jumped: jumped, tempoMap: tempoMap, bookends: bookends, sequence: &tempoSequence,
                )
            }
            if voiceIndex == 0,
               entry.measureIndex < systemElementsByMeasure.count
            {
                for positioned in systemElementsByMeasure[entry.measureIndex] {
                    let tickAt = entry.tickOffset
                        + positioned.position.ticks(division: division)
                    switch positioned.element {
                    case .tempo:
                        // The tempo map supplies both the meta (above) and the tempo the breath and
                        // arpeggio arithmetic read (below, per element).
                        break
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
            // What to ADD to a running `localTick` to get the tick the swing grid should read: back to the bar's
            // own zero, then forward by however much of a notional full bar a pickup is missing.
            let swingGridBase = (entry.measureIndex < anacrusisOffsets.count
                ? anacrusisOffsets[entry.measureIndex].ticks(division: division)
                : 0) - entry.tickOffset
            // Indices of `.chord` elements consumed by a preceding
            // two-note tremolo. The voice walker still advances
            // `localTick` past them so subsequent elements land
            // correctly, but emits no note events for the consumed
            // follower.
            var consumedByTremolo: Set<Int> = []
            for (elementIndex, element) in effectiveVoice.elements.enumerated() {
                // The tempo where this element stands — its nominal tick, before the pauses earlier in the bar — is
                // what a breath's pause and an arpeggio's spread are converted at (import-fidelity F2.9).
                currentTempoBps = tempoMap.beatsPerSecond(
                    atMeasure: entry.measureIndex,
                    tickInMeasure: localTick - entry.tickOffset - pauseTicksInMeasure,
                )
                let tickBeforeElement = localTick
                // Everything this walk looks up by original tick — channel switches, capos, swing, dynamics, ottavas —
                // stands at a bar's nominal positions; the walk's tick also counts the breath pauses earlier in the
                // bar, which must not carry an element across any of them. `localTick` itself keeps the pauses: it
                // places the events.
                let nominalDelta = originalTickDelta - pauseTicksInMeasure
                let nominalOriginalTick = localTick + nominalDelta
                var channel = channel(atOriginalTick: nominalOriginalTick)
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
                // The capo works the same way: a tie's continuation keeps the pitch its head sounded, so a capo
                // that changes under a tie neither retunes the held note nor leaves the head's note-on unreleased.
                // Like the channel, it is resolved per chord: a fresh note struck beside a tied one, on the very tick
                // a capo changes, sounds through the tie head's capo too.
                var capo = CapoRanges.active(in: capoPoints, at: nominalOriginalTick)
                if case let .chord(chord) = element {
                    if chord.notes.contains(where: { $0.tieBack != nil }),
                       let sustained = sustainedChannel
                    {
                        channel = sustained
                    }
                    if chord.notes.contains(where: { $0.tieBack != nil }), let sustained = sustainedCapo {
                        capo = sustained
                    }
                    let continues = chord.notes.contains(where: { $0.tieForward != nil })
                    sustainedChannel = continues ? channel : nil
                    sustainedCapo = continues ? .some(capo) : nil
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
                        voiceElements: effectiveVoice.elements.values,
                        measureDuration: measureDuration,
                        localTick: &localTick,
                        consumedByTremolo: &consumedByTremolo,
                        channel: channel,
                        division: division,
                        events: &events,
                        dynamics: dynamics,
                        ottavaRanges: ottavaRanges,
                        capo: capo,
                        originalTickDelta: nominalDelta,
                    )
                    continue
                }
                renderVoiceElement(
                    element,
                    elementIndex: elementIndex,
                    bendChainSlots: bendChainSlots[elementIndex],
                    voiceElements: effectiveVoice.elements.values,
                    voiceTuplets: effectiveVoice.tupletSpans,
                    measures: staff.measures,
                    measureIndex: entry.measureIndex,
                    measureDuration: measureDuration,
                    currentKey: currentKey,
                    localTick: &localTick,
                    currentTempoBps: &currentTempoBps,
                    swingMap: swingMap,
                    swingGridBase: swingGridBase,
                    voiceIndex: voiceIndex,
                    channel: channel,
                    instrument: part.instrument,
                    division: division,
                    events: &events,
                    lyricAnchors: &lyricAnchors,
                    dynamics: dynamics,
                    ottavaRanges: ottavaRanges,
                    capo: capo,
                    originalTickDelta: nominalDelta,
                    tieGateDebt: &tieGateDebt,
                )
                if case .breath = element { pauseTicksInMeasure += localTick - tickBeforeElement }
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
                measureIndex: last.measureIndex, tempoMap: tempoMap,
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
        voiceTuplets: [TupletSpan],
        measures: [Measure],
        measureIndex: Int,
        measureDuration: Fraction,
        currentKey: Int,
        localTick: inout Int,
        currentTempoBps: inout Double,
        swingMap: SwingMap,
        // What to ADD to `localTick` to get the tick the swing grid reads: the bar's own zero, shifted forward by
        // a pickup's shortfall. See `[Measure].anacrusisOffsets()`.
        swingGridBase: Int,
        voiceIndex: Int,
        channel: Int,
        instrument: Instrument,
        division: Int,
        events: inout [TimedMidiEvent],
        lyricAnchors: inout [LyricMidiCodec.Anchor],
        dynamics: DynamicsTimeline,
        ottavaRanges: [OttavaRange],
        capo: CapoPoint?,
        originalTickDelta: Int,
        tieGateDebt: inout [Int: Int],
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
        // Text annotations, string tunings, and ambitus range indicators
        // produce no MIDI events. A capo reaches the chords through `CapoRanges` (the `capo` the walk resolved), a
        // dynamic through `DynamicsTimeline`.
        case .clef, .barLine, .spanner, .measureRepeat, .harmony,
             .sticking, .expression, .capo, .stringTunings, .ambitus, .figuredBass, .symbol, .fretDiagram,
             .preserved, .dynamic:
            return
        case let .locationShift(delta):
            // Voice cursor shift: applies the location's fractional
            // delta to the running tick so subsequent dynamic /
            // marker events land at the correct beat. Mirrors
            // `LayoutEngine`'s placement-side handling.
            localTick += delta.ticks(division: division)
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
            // A legacy `<Bend>` curve needs the note's whole sounding
            // length, so its tie chain is resolved here — one element's
            // ticks are not enough, and the walk cannot see forward once
            // it is inside `renderChordWithGraces`.
            let legacyBendSpans = MidiRenderer.legacyBendSpans(
                chord: chord,
                voiceElements: voiceElements,
                elementIndex: elementIndex,
                measureDuration: measureDuration,
                division: division,
            )
            // Apply swing: shift the onset and adjust the played
            // duration per the active swing state. `localTick` itself
            // continues to advance by the chord's NOMINAL duration, so
            // a swung onset never drags the notes after it — the shift
            // is applied to the event, not accumulated.
            //
            // `localTick` is the unrolled playback tick, counted from
            // the score's own zero. It is what the swing STATE is
            // looked up with (the map is keyed that way), but not what
            // the grid is read with — see `swingGridBase`.
            let chordTicks = chord.duration
                .resolved(in: measureDuration)
                .ticks(division: division)
            let adjust = swingAdjustment(
                // Measured from the BAR, not from the score's tick 0: a pickup shifts every later bar line off the
                // pair grid, and the two halves of every swung pair then swap roles. MuseScore reads
                // `chord->rtick() + measure->anacrusisOffset()` here for the same reason (`dom/swing.cpp`).
                startTick: localTick + swingGridBase,
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
            // The velocity is the timeline's at the swing-adjusted onset, so it tracks the audible attack rather than
            // the nominal grid: a ramp in force there, else the level the dynamics put in force (`DynamicsTimeline`).
            let onsetOriginalTick = (localTick + adjust.onsetShift) + originalTickDelta
            let chordVelocity = dynamics.velocity(atOriginalTick: onsetOriginalTick)
            let ottavaShift = OttavaRanges.semitones(
                in: ottavaRanges, at: onsetOriginalTick,
            )
            // At the chord's notated tick, as MuseScore reads the capo at its segment's.
            renderChordWithGraces(
                capo.map { CapoRanges.compensate(chord, for: $0) } ?? chord,
                tick: localTick + adjust.onsetShift,
                velocity: chordVelocity,
                channel: channel,
                instrument: instrument,
                tempoBps: currentTempoBps,
                division: division,
                glissandoEndPitch: glissandoEndPitch,
                bendChainSlots: bendChainSlots,
                legacyBendSpans: legacyBendSpans,
                currentKey: currentKey,
                events: &events,
                tieGateDebt: &tieGateDebt,
                playedTicksOverride: adjust == .none
                    ? nil
                    : max(1, chordTicks + adjust.lengthDelta),
                pitchShift: ottavaShift + (capo?.fret ?? 0),
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
            // forward at the tempo where the breath stands — exactly what MuseScore's
            // MIDI export does. Verified by dumping `mscore -o` output:
            // tempo stays unchanged across the pause; the next chord's
            // delta increases by `pause × bps × ppq` ticks.
            //
            // Mirrors mu::engraving::Breath::play() / MuseScore's
            // ExportMidi pauseMap → tick-advance lowering.
            if breath.pause > 0 {
                localTick += breathPauseTicks(breath.pause, beatsPerSecond: currentTempoBps, division: division)
            }
        }
    }

    // The per-note emit used to live here as `emitNoteEvents`, but every
    // chord has routed through `renderChordWithGraces` since grace-note
    // support landed, leaving this copy unreachable. The live one is
    // `emitNoteEventsForGrace` in `MidiRenderer+Grace.swift`.

    static func effectiveVelocity(forDynamic dynamic: Dynamic?, instrument: Instrument) -> Int {
        effectiveVelocity(level: dynamic?.velocity ?? defaultDynamicVelocity, instrument: instrument)
    }

    /// A `dynList` level velocity (`Dynamic.PlaybackRole`) on this instrument: scaled by its default articulation's
    /// velocity percentage, as every dynamic's velocity is.
    static func effectiveVelocity(level: Int, instrument: Instrument) -> Int {
        let scale = defaultArticulationVelocityScale(for: instrument)
        return min(127, max(1, level * scale / 100))
    }

    static func defaultArticulationVelocityScale(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.velocity ?? 100
    }

    static func defaultArticulationGateTime(for instrument: Instrument) -> Int {
        instrument.articulations.first(where: { $0.name == nil })?.gateTime ?? 100
    }

    /// Per-chord gateTime lookup. Filters `chord.articulations` to the in-scope duration-shaping kinds (staccato /
    /// staccatissimo / tenuto / tenuto-staccato, which MuseScore plays from its "portato" preset), looks each up in
    /// the instrument preset table, and returns the **minimum** gateTime% among the candidates (matches MuseScore's
    /// `MidiArticulation::aggregateOf` — most-shortening wins). When no in-scope articulation is present, falls
    /// through to `defaultArticulationGateTime(for:)` so existing behavior is preserved. C++:
    ///   engraving/compat/midi/compatmidirender.cpp
    ///   `CompatMidiRender::collectMeasureEvents` — `articulationGateTime`.
    static func effectiveGateTime(for chord: Chord, instrument: Instrument) -> Int {
        let gates = chord.articulations.compactMap { art -> Int? in
            guard let (presetName, hardcodedDefault) = gatePreset(for: art.kind) else { return nil }
            return instrument.articulations
                .first(where: { $0.name == presetName })?
                .gateTime ?? hardcodedDefault
        }
        if let minimum = gates.min() {
            return minimum
        }
        return defaultArticulationGateTime(for: instrument)
    }

    /// The instrument preset a kind shortens its notes by, and the gate% used when the instrument names none.
    /// A combined mark takes its duration-shaping half's preset, the way `accentStaccato` always has; the stroke and
    /// wedge staccatissimos are "staccatissimo" (`symId2ArticulationName`), and the louré is "portato", 67%
    /// (`s_builtInArticulationsValues`). `nil` for a mark that does not shape duration.
    private static func gatePreset(for kind: ChordArticulation.Kind) -> (String, Int)? {
        switch kind {
        case .staccato, .accentStaccato, .marcatoStaccato, .softAccentStaccato: ("staccato", 50)
        case .staccatissimo, .staccatissimoStroke, .staccatissimoWedge: ("staccatissimo", 33)
        case .tenuto, .tenutoAccent, .marcatoTenuto, .softAccentTenuto: ("tenuto", 100)
        case .tenutoStaccato, .softAccentTenutoStaccato: ("portato", 67)
        case .accent, .marcato, .stress, .unstress, .softAccent, .muteOpen, .muteClosed, .harmonic, .upBow,
             .downBow, .laissezVibrer, .unknown:
            nil
        }
    }

    /// The instrument preset a kind scales velocity by, and the % used when the instrument names none — the accent
    /// or marcato half of a combined mark. `nil` for a mark that does not shape velocity.
    private static func velocityPreset(for kind: ChordArticulation.Kind) -> (String, Int)? {
        switch kind {
        case .accent, .accentStaccato, .tenutoAccent: ("accent", 120)
        case .marcato, .marcatoStaccato, .marcatoTenuto: ("marcato", 120)
        case .staccato, .staccatissimo, .tenuto, .tenutoStaccato, .staccatissimoStroke, .staccatissimoWedge,
             .stress, .unstress, .softAccent, .softAccentStaccato, .softAccentTenuto, .softAccentTenutoStaccato,
             .muteOpen, .muteClosed, .harmonic, .upBow, .downBow, .laissezVibrer, .unknown:
            nil
        }
    }

    /// Per-chord velocity-scale lookup. Filters `chord.articulations`
    /// to the in-scope velocity-shaping kinds (accent / marcato and the
    /// combined forms carrying one, `velocityPreset(for:)`), looks each up in the
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
            guard let (presetName, hardcodedDefault) = velocityPreset(for: art.kind) else { return nil }
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
