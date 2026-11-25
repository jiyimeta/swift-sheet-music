import SheetMusicCore

// swiftlint:disable file_length
import SheetMusicFoundation

extension MidiRenderer {
    /// Default playback length of one grace note in ticks.
    /// Mirrors `CompatMidiRender::graceTickLen` — appoggiatura is
    /// proportional to the parent (`mainTicks/2`); the rest are
    /// constants in PPQ. `acciaccatura` is intentionally short
    /// (1/32 of a quarter) so it reads as a "crushed" ornament.
    static func playbackTicks(
        for grace: GraceChord, mainTicks: Int, division: Int,
    ) -> Int {
        switch grace.graceType {
        case .acciaccatura: return division / 8 // 1/32 of a quarter
        case .appoggiatura: return max(0, mainTicks / 2)
        case .grace4: return division // 1/4 = quarter
        case .grace16: return division / 4
        case .grace32: return division / 8
        case .grace8after: return division / 2
        case .grace16after: return division / 4
        case .grace32after: return division / 8
        }
    }

    /// Time stolen from the *previous* chord's tail. Only
    /// acciaccaturas steal from the previous chord; every other
    /// before-grace steals from the parent chord's head.
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore`.
    static func totalStealFromPrev(
        _ before: [GraceChord], division: Int,
    ) -> Int {
        before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc + playbackTicks(for: g, mainTicks: 0, division: division)
                : acc
        }
    }

    /// Time stolen from the *parent* chord's head. Sum of every
    /// before-grace's playback length, EXCEPT acciaccatura (which
    /// steals from the previous chord). Capped at mainTicks/2 to
    /// keep the parent audible — MuseScore's
    /// `handleOverflowsForGrace` does a non-linear shrink; we do
    /// a single proportional clamp because it handles every realistic
    /// score and stays simple.
    static func totalStealFromMainHead(
        _ before: [GraceChord], mainTicks: Int, division: Int,
    ) -> Int {
        let raw = before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc
                : acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

    /// Time stolen from the *parent* chord's tail to fit
    /// after-graces. Same capping rule as the head.
    static func totalStealFromMainTail(
        _ after: [GraceChord], mainTicks: Int, division: Int,
    ) -> Int {
        let raw = after.reduce(0) { acc, g in
            acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

    /// Render one parent chord and its surrounding grace notes.
    /// Steals time per the helpers above:
    ///
    ///   prev.tail   ─stealFromPrev─►  before-graces (acciaccatura only)
    ///   main.head   ─stealFromHead─►  before-graces (everything else)
    ///   main.tail   ─stealFromTail─►  after-graces
    ///
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore` /
    /// `renderGraceNotesAfter` semantics, simplified for this codebase
    /// (no per-grace velocity scaling — see spec Non-goals).
    ///
    /// That is `graceTiming: .smfExport`. Under `.performance` every grace
    /// note before the chord takes its time from the chord's head
    /// (`GraceTiming`). A chord whose notes carry a bend chain keeps the
    /// export's placement either way: its wheel is written against it.
    ///
    /// `ornaments` says how each note is ornamented, by its place in
    /// `originalChord.notes`.
    static func renderChordWithGraces( // swiftlint:disable:this function_body_length function_parameter_count
        _ originalChord: Chord,
        tick: Int,
        velocity: Int,
        channel: Int,
        instrument: Instrument,
        tempoBps: Double,
        division: Int,
        glissandoEndPitch: Int?,
        bendChainSlots: BendChainChordSlots? = nil,
        legacyBendSpans: [Int: Int] = [:],
        currentKey: Int,
        events: inout [TimedMidiEvent],
        tieGateDebt: inout [Int: Int],
        chokes: inout ChokeChains,
        playedTicksOverride: Int? = nil,
        pitchShift: Int = 0,
        graceTiming: GraceTiming = .smfExport,
        isCompoundMeter: Bool = false,
        ornaments: [NoteOrnament?] = [],
    ) {
        // Apply an ottava transposition to every sounding pitch
        // (parent + grace notes). Clamping to MIDI's 0..127 keeps a
        // 22ma chord audible at the extremes rather than wrapping.
        let chord = pitchShift == 0
            ? originalChord
            : transpose(originalChord, by: pitchShift)
        let shiftedGlissandoEnd = glissandoEndPitch.map {
            min(127, max(0, $0 + pitchShift))
        }
        // The chain's sounding key rides the ottava like every other pitch.
        let shiftedBendSlots = bendChainSlots.map { shifted($0, by: pitchShift) }
        // …and so does the key of the legacy-bend span map, which the note
        // loop looks up with a TRANSPOSED pitch. Without this the lookup
        // misses under any ottava and the curve is lost with no diagnostic.
        // The 0…127 clamp can fold two source pitches onto one key at the
        // extremes; the source pitches are walked in ascending order so the
        // lower one wins deterministically (a Dictionary's own iteration
        // order is not stable across runs).
        let shiftedLegacySpans = pitchShift == 0 ? legacyBendSpans : Dictionary(
            legacyBendSpans.keys.sorted().map {
                (min(127, max(0, $0 + pitchShift)), legacyBendSpans[$0] ?? 0)
            },
            uniquingKeysWith: { first, _ in first },
        )
        // `playedTicksOverride` is set by the swing pass to express
        // a chord whose audible length differs from its written
        // duration (off-beat shift / down-beat extension). The grace
        // allocation and gate-time math work off the audible length
        // so swung chords keep proportional grace timing.
        let mainTicks = playedTicksOverride
            ?? chord.duration.ticks(division: division)
        let graces = graceLayout(
            for: chord, timing: bendChainSlots == nil ? graceTiming : .smfExport,
            tick: tick, mainTicks: mainTicks, division: division, isCompoundMeter: isCompoundMeter,
        )
        let stealFromPrev = graces.stealFromPrev
        let stealFromHead = graces.stealFromHead
        let stealFromTail = graces.stealFromTail

        // 1. Pull preceding noteOffs (this voice / channel only) back
        // by `stealFromPrev`, clamped so they never precede their
        // own noteOn. Without this clamp a back-to-back acciaccatura
        // followed by a very short prev chord would overlap.
        if stealFromPrev > 0 {
            let prevNoteOnTicks = collectPriorNoteOnTicks(
                in: events, channel: channel,
            )
            for i in events.indices.reversed() {
                // A choke marker sits on its note-off's tick (`ChokeChains`) and moves with it.
                if events[i].tick <= tick - 1, events[i].tick > tick - 1 - stealFromPrev,
                   case let .controlChange(ch, controller, key) = events[i].event,
                   ch == channel, controller == ChokeMarker.controller
                {
                    let onTick = prevNoteOnTicks[key] ?? events[i].tick
                    events[i].tick = max(onTick + 1, events[i].tick - stealFromPrev)
                    continue
                }
                guard events[i].tick <= tick - 1,
                      events[i].tick > tick - 1 - stealFromPrev,
                      case let .noteOff(ch, pitch, vel) = events[i].event,
                      ch == channel
                else { continue }
                let onTick = prevNoteOnTicks[pitch] ?? events[i].tick
                let target = max(onTick + 1, events[i].tick - stealFromPrev)
                events[i] = TimedMidiEvent(
                    tick: target,
                    event: .noteOff(channel: ch, pitch: pitch, velocity: vel),
                )
            }
        }

        // 2. Emit before-graces.
        for (graceIndex, g) in chord.graceNotesBefore.enumerated() {
            let slot = graces.before[graceIndex]
            emitGraceChord(
                g, slot: shiftedBendSlots?.before[graceIndex],
                onset: max(0, tick + slot.offset), durationTicks: slot.ticks,
                velocity: velocity, channel: channel, events: &events,
            )
        }

        // 3. Main chord — onset shifted by stealFromHead, length
        //    shortened by stealFromHead + stealFromTail.
        let mainOnset = tick + stealFromHead
        let playedTicks = max(1, mainTicks - stealFromHead - stealFromTail)
        let gate = effectiveGateTime(for: chord, instrument: instrument)
        let gatedTicks = playedTicks * gate / 100
        let mainOff = mainOnset + gatedTicks - 1
        let mainVelocity = adjustVelocityForChord(
            baseVelocity: velocity,
            chord: chord,
            instrument: instrument,
        )
        // The choke marker goes at the note-off of a note that ends its tie chain (`ChokeChains`).
        let chordChokes = ChokeChains.marks(chord)
        func release(_ note: Note, at offTick: Int) {
            guard note.play, let marker = chokes.release(
                key: note.pitch, tiesBack: note.tieBack != nil, tiesForward: note.tieForward != nil,
                marked: chordChokes, channel: channel, offTick: offTick,
            ) else { return }
            events.append(marker)
        }
        if let arpeggio = chord.arpeggio {
            // Keep arpeggio behavior intact: same call as the
            // pre-grace path, just with the shifted onset / shortened
            // length. This preserves the existing arpeggio tests.
            let pairs = arpeggioNoteEvents(
                noteCount: chord.notes.count,
                chordTicks: playedTicks,
                stretch: arpeggio.timeStretch,
                tempoBps: tempoBps,
            )
            let order = arpeggio.isAscending
                ? Array(0 ..< chord.notes.count)
                : Array((0 ..< chord.notes.count).reversed())
            for (i, noteIndex) in order.enumerated() {
                let note = chord.notes[noteIndex]
                tieGateDebt[note.pitch] = nil
                let onTick = mainOnset + pairs[i].onOffset
                let offTick = mainOnset + pairs[i].offOffset
                emitNoteEventsForGrace(
                    note: note, channel: channel, velocity: mainVelocity,
                    onTick: onTick, offTick: offTick, events: &events,
                )
                release(note, at: offTick)
            }
        } else {
            // Only the bend-carrying note of the chord drives the chain; the
            // rest emit normally and are dragged along by the channel-wide
            // wheel (see `guitarBendChains`' chord-level simplification).
            let parentSlot = shiftedBendSlots?.parent
            let chainPitch = parentSlot == nil
                ? nil
                : bendChainNote(in: chord.notes)?.pitch
            for (noteIndex, note) in chord.notes.enumerated() {
                // A bent, slid or legacy-bent note releases on its own curve, outside the gate account.
                let isShaped = (parentSlot != nil && note.pitch == chainPitch)
                    || (note.glissando != nil && shiftedGlissandoEnd != nil)
                    || (note.legacyBend != nil && shiftedLegacySpans[note.pitch] != nil)
                if isShaped {
                    tieGateDebt[note.pitch] = nil
                    chokes.drop(key: note.pitch)
                }
                if let slot = parentSlot, note.pitch == chainPitch {
                    renderBendChainNote(
                        note: note, slot: slot,
                        startTick: mainOnset, durationTicks: playedTicks,
                        velocity: mainVelocity, channel: channel,
                        events: &events,
                    )
                } else if let glissando = note.glissando, let endPitch = shiftedGlissandoEnd {
                    renderGlissandoNote(
                        note: note, glissando: glissando, endPitch: endPitch,
                        startTick: mainOnset, durationTicks: playedTicks,
                        velocity: mainVelocity, channel: channel,
                        currentKey: currentKey, events: &events,
                    )
                } else if let legacyBend = note.legacyBend,
                          let totalTicks = shiftedLegacySpans[note.pitch]
                {
                    // Last of the three: the MS4 spanner is the newer
                    // encoding of the same gesture (`Note.legacyBend`), and
                    // glissando keeps the priority it had before bends
                    // existed. `legacyBendSpans` has already refused every
                    // shape that must play plain, so nothing is re-guarded.
                    renderLegacyBendNote(
                        note: note, bend: legacyBend,
                        startTick: mainOnset, durationTicks: gatedTicks,
                        totalTicks: totalTicks,
                        velocity: mainVelocity, channel: channel,
                        events: &events,
                    )
                } else {
                    var onTick = mainOnset
                    if ornaments.indices.contains(noteIndex), let ornament = ornaments[noteIndex],
                       let subNotes = ornament.figure.subNotes(
                           totalTicks: playedTicks, division: division, beatsPerSecond: tempoBps,
                           isContinuing: ornament.isContinuing,
                       )
                    {
                        guard let held = emitOrnament(
                            subNotes, of: note, ornament: ornament, onset: mainOnset, mainOff: mainOff,
                            velocity: mainVelocity, channel: channel, events: &events,
                        ) else {
                            tieGateDebt[note.pitch] = nil
                            continue
                        }
                        onTick = held
                    } else if ornaments.indices.contains(noteIndex), ornaments[noteIndex]?.isContinuing == true {
                        // Too short to carry the trill its tie brought, whose notes are all let go of: struck again.
                        emitOrnamentNote(
                            note, semitones: 0, from: mainOnset, to: mainOff,
                            velocity: mainVelocity, channel: channel, events: &events,
                        )
                        tieGateDebt[note.pitch] = nil
                        continue
                    }
                    let offTick = tieGatedOff(
                        of: note, mainOff: mainOff, droppedByGate: playedTicks - gatedTicks, debt: &tieGateDebt,
                    )
                    emitNoteEventsForGrace(
                        note: note, channel: channel, velocity: mainVelocity,
                        onTick: onTick, offTick: offTick, events: &events,
                    )
                    release(note, at: offTick)
                }
            }
        }

        // 4. After-graces — share the tail slot the main gave up.
        for (graceIndex, g) in chord.graceNotesAfter.enumerated() {
            let slot = graces.after[graceIndex]
            emitGraceChord(
                g, slot: shiftedBendSlots?.after[graceIndex],
                onset: tick + slot.offset, durationTicks: slot.ticks,
                velocity: velocity, channel: channel, events: &events,
            )
        }
    }

    /// Emit an ornament's notes. A figure that ends by holding the written note leaves that last note to the caller,
    /// which strikes it at the returned tick and lets go of it by the tie's rules; `nil` says everything is emitted.
    private static func emitOrnament(
        _ subNotes: [OrnamentFigure.SubNote], of note: Note, ornament: NoteOrnament, onset: Int, mainOff: Int,
        velocity: Int, channel: Int, events: inout [TimedMidiEvent],
    ) -> Int? {
        for (index, sub) in subNotes.enumerated() {
            let isLast = index == subNotes.count - 1
            if isLast, sub.step == 0, !ornament.figure.repeatsBody { return onset + sub.offset }
            emitOrnamentNote(
                note, semitones: ornament.semitones(forStep: sub.step), from: onset + sub.offset,
                to: isLast ? max(onset + sub.offset, mainOff) : onset + sub.offset + sub.ticks - 1,
                velocity: velocity, channel: channel, events: &events,
            )
        }
        return nil
    }

    /// One struck and released note of an ornament. The written note keeps its own tuning; a neighbor outside MIDI's
    /// range is left out.
    private static func emitOrnamentNote(
        _ note: Note, semitones: Int, from onTick: Int, to offTick: Int,
        velocity: Int, channel: Int, events: inout [TimedMidiEvent],
    ) {
        let pitch = note.pitch + semitones
        guard note.play, (0 ... 127).contains(pitch) else { return }
        events.append(.noteOn(
            tick: onTick, channel: channel, pitch: pitch, velocity: note.customizedVelocity(velocity),
            cents: semitones == 0 ? note.playbackCents : 0,
        ))
        events.append(TimedMidiEvent(
            tick: max(onTick, offTick), event: .noteOff(channel: channel, pitch: pitch, velocity: 0),
        ))
    }

    /// Every slot of `slots` with its sounding key transposed — the chain
    /// rides an ottava like any other pitch.
    private static func shifted(
        _ slots: BendChainChordSlots, by semitones: Int,
    ) -> BendChainChordSlots {
        guard semitones != 0 else { return slots }
        func shift(_ slot: BendChainSlot) -> BendChainSlot {
            var copy = slot
            copy.basePitch = min(127, max(0, slot.basePitch + semitones))
            return copy
        }
        var copy = slots
        copy.parent = slots.parent.map(shift)
        copy.before = slots.before.mapValues(shift)
        copy.after = slots.after.mapValues(shift)
        return copy
    }

    // swiftlint:disable:next function_parameter_count
    /// Emit one grace chord's note events.
    ///
    /// A grace note is an ordinary member of a bend chain — MuseScore's
    /// `collectGuitarBend` follows `bendFor()` links without caring whether
    /// the note it lands on is a grace, and starts the wheel segment at the
    /// GRACE's onset for a `GRACE_NOTE_BEND`
    /// (`curPitchBendSegmentStart -= graceOffset`). So the chain member here
    /// goes through `renderBendChainNote`, which strikes the key only at the
    /// chain's head and releases it only at its end; every other grace note
    /// keeps its own plain on/off pair.
    private static func emitGraceChord(
        _ grace: GraceChord,
        slot: BendChainSlot?,
        onset: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        let chainPitch = slot == nil ? nil : bendChainNote(in: grace.notes)?.pitch
        for note in grace.notes where note.play {
            if let slot, note.pitch == chainPitch {
                renderBendChainNote(
                    note: note, slot: slot,
                    startTick: onset, durationTicks: durationTicks,
                    velocity: velocity, channel: channel, events: &events,
                )
                continue
            }
            events.append(.noteOn(
                tick: onset, channel: channel, pitch: note.pitch,
                velocity: note.customizedVelocity(velocity), cents: note.playbackCents,
            ))
            events.append(TimedMidiEvent(
                tick: max(0, onset + durationTicks - 1),
                event: .noteOff(
                    channel: channel, pitch: note.pitch, velocity: 0,
                ),
            ))
        }
    }

    /// Return a copy of `chord` with every parent and grace-note pitch
    /// shifted by `semitones` and clamped to MIDI's 0..127 range. Used
    /// only by the ottava transposition path; pitches that overflow
    /// pin to the extreme rather than wrapping octaves.
    static func transpose(_ chord: Chord, by semitones: Int) -> Chord {
        guard semitones != 0 else { return chord }
        var result = chord
        result.notes.mapValues { transpose($0, by: semitones) }
        result.graceNotesBefore.mapValues {
            transpose($0, by: semitones)
        }
        result.graceNotesAfter.mapValues {
            transpose($0, by: semitones)
        }
        return result
    }

    private static func transpose(
        _ grace: GraceChord, by semitones: Int,
    ) -> GraceChord {
        var copy = grace
        copy.notes.mapValues { transpose($0, by: semitones) }
        return copy
    }

    private static func transpose(_ note: Note, by semitones: Int) -> Note {
        var copy = note
        copy.pitch = min(127, max(0, note.pitch + semitones))
        return copy
    }

    /// Map of pitch → most recent noteOn tick on `channel`. Used by
    /// the prev-chord shortening pass to avoid pulling a noteOff in
    /// past its own noteOn.
    private static func collectPriorNoteOnTicks(
        in events: [TimedMidiEvent], channel: Int,
    ) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for e in events {
            if case let .noteOn(ch, pitch, _) = e.event, ch == channel {
                map[pitch] = e.tick
            }
        }
        return map
    }

    /// Where a note's release lands once its whole tie chain is gated, not just its last link.
    ///
    /// MuseScore shortens EVERY link of a tie chain by its gate and adds the links up (`CompatMidiRender`'s
    /// `calculateTieLength`), so a chain sounds gate% of its whole length however it is spelled: a dotted half and a
    /// half tied to a quarter release at the same tick. Only the last link emits a note-off here, gated by its own
    /// length, so each earlier link records in `debt` (per sounding pitch, for the voice walk's open chains) the ticks
    /// its gate dropped, and the last one takes the sum off its own release. A note with no tie in starts a fresh
    /// account.
    static func tieGatedOff(of note: Note, mainOff: Int, droppedByGate: Int, debt: inout [Int: Int]) -> Int {
        let carried = note.tieBack == nil ? 0 : debt[note.pitch] ?? 0
        guard note.tieForward == nil else {
            debt[note.pitch] = carried + max(0, droppedByGate)
            return mainOff
        }
        debt[note.pitch] = nil
        return max(0, mainOff - carried)
    }

    /// Emit note-on/off for a single note, respecting tie flags. For a
    /// tied chain we want ONE combined event pair:
    ///   - A note with `tieBack` set must not re-trigger: its note-on is
    ///     suppressed because the preceding chord's note-on still sounds.
    ///   - A note with `tieForward` set must not release: its note-off is
    ///     suppressed because the sound continues into the next chord.
    /// Mirrors MuseScore's `Note::playTicksFraction()`, which reports the
    /// full tied span as the single sounding event.
    private static func emitNoteEventsForGrace(
        note: Note,
        channel: Int,
        velocity: Int,
        onTick: Int,
        offTick: Int,
        events: inout [TimedMidiEvent],
    ) {
        // A muted note (`<play>0</play>`) emits no MIDI. Mirrors the
        // `if (!note->play()) return;` guard in CompatMidiRender::collectNote.
        guard note.play else { return }
        let velocity = note.customizedVelocity(velocity)
        if note.tieBack == nil {
            events.append(.noteOn(
                tick: onTick, channel: channel, pitch: note.pitch, velocity: velocity, cents: note.playbackCents,
            ))
        }
        if note.tieForward == nil {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: note.pitch, velocity: 0),
            ))
        }
    }
}
