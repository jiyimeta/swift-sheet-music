import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// Per-voice-element bend-chain playback state, computed in a pre-pass
    /// before the voice walk. Keyed by `elementIndex` within the voice.
    ///
    /// A guitar bend is not a second attack: the string keeps ringing and the
    /// player pushes it up, so a whole chain of notated pitches sounds as ONE
    /// MIDI key with the pitch wheel doing the work. Each chord in the chain
    /// gets one slot describing where the wheel already is when the chord
    /// starts and where it has to be by the time the chord ends.
    struct BendChainSlot: Equatable {
        /// MIDI key that actually sounds for this chord's bend chain
        /// (the chain's first note pitch).
        var basePitch: Int
        /// Wheel offset in quarter tones already applied when this chord starts.
        var startOffsetQuarterTones: Int
        /// Offset to ramp to during this chord (nil = hold; chain end).
        var targetOffsetQuarterTones: Int?
        var isChainStart: Bool
        var isChainEnd: Bool
        /// Time factors of the bend that *starts* on this chord (chain-end
        /// slots have none, and hold across the whole chord).
        var startTimeFactor: Double
        var endTimeFactor: Double
    }

    // MARK: - Chain construction

    /// Bend-chain slots for one voice's elements, keyed by element index.
    ///
    /// Mirrors the chain walk in MuseScore's MIDI compatibility renderer
    /// (`engraving/compat/midi/compatmidirenderinternal.cpp`): the begin note
    /// of a `<Spanner type="GuitarBend">` pair owns the payload, and each
    /// `<prev>`-side note continues the same sounding key rather than striking
    /// a new one.
    ///
    /// Suppression keys off THIS map, never off `Note.guitarBendBack` alone: a
    /// `<prev>`-only spanner survives decoding when its begin side was dropped
    /// (unknown `<guitarBendType>`, missing `<GuitarBend>` payload), and such a
    /// note has to attack normally or it would be silent.
    ///
    /// ## What v1 deliberately does not curve
    ///
    /// - `preBend` — MuseScore takes a pre-bend's distance from the tab fret
    ///   data (the parenthesised grace note is the *fretted* pitch, the
    ///   principal is the *bent* one), which this model does not carry, so
    ///   there is no pitch delta to ramp. The note plays straight at its
    ///   written pitch with the wheel untouched.
    /// - `graceNoteBend` — grace-attached bends are handled in a later pass;
    ///   the walk below only sees `voiceElements`, never `graceNotesBefore` /
    ///   `graceNotesAfter`.
    /// - Any chain touching a tie. A chain re-decides for itself when the key
    ///   is struck and released, which is exactly what the tie flags in
    ///   `emitNoteEventsForGrace` also decide; running both without composing
    ///   them drops the tied tail (measured on `guitarbend_tied`: the closing
    ///   half note lost its whole sound). Excluding tied chains keeps those
    ///   scores playing as they did before bends existed, at the cost of the
    ///   bend curve, until the two suppression rules are merged.
    /// - The four whammy-bar types (`dive`, `preDive`, `dip`, `scoop`) — their
    ///   depth lives in properties this model announces and drops at decode.
    ///
    /// ## Chord-level simplification
    ///
    /// The pitch wheel is a channel-wide control, so a chord that mixes bent
    /// and unbent notes bends all of them. MuseScore's own MIDI export has the
    /// same limitation; bends are single-note in practice.
    static func guitarBendChains(voiceElements: [VoiceElement]) -> [Int: BendChainSlot] {
        var slots: [Int: BendChainSlot] = [:]
        var index = 0
        while index < voiceElements.count {
            guard let chain = bendChain(voiceElements: voiceElements, startingAt: index) else {
                index += 1
                continue
            }
            for (elementIndex, slot) in chain {
                slots[elementIndex] = slot
            }
            index = (chain.last?.0 ?? index) + 1
        }
        return slots
    }

    /// The note a chord's bend chain sounds on: the first note carrying either
    /// side of a `<Spanner type="GuitarBend">` pair. The chord-level
    /// simplification documented on `guitarBendChains` is what makes "first"
    /// good enough.
    static func bendChainNote(in chord: Chord) -> Note? {
        chord.notes.first { $0.guitarBend != nil || $0.guitarBendBack }
    }

    /// One complete chain starting at `startIndex`, or nil when the element is
    /// not a chain head or the chain cannot be completed. Returning nil for an
    /// incomplete chain is deliberate: every member then falls back to a plain
    /// attack, which keeps the note-on/off stream balanced. A chain whose
    /// destination sits in the next measure lands here too — the walk sees one
    /// voice's elements at a time.
    private static func bendChain(
        voiceElements: [VoiceElement],
        startingAt startIndex: Int,
    ) -> [(Int, BendChainSlot)]? {
        guard let head = chainCapableNote(in: voiceElements, at: startIndex),
              let headBend = head.guitarBend,
              startsChain(headBend.type)
        else { return nil }
        let basePitch = head.pitch
        var chain: [(Int, BendChainSlot)] = []
        var offsetQuarterTones = 0
        var index = startIndex
        var bend = headBend
        while true {
            // A slight bend is a quarter-tone scoop with no notated
            // destination: it begins and ends on the same note, ramps up and
            // HOLDS — MuseScore never brings it back down.
            if bend.type == .slightBend {
                chain.append((index, BendChainSlot(
                    basePitch: basePitch,
                    startOffsetQuarterTones: offsetQuarterTones,
                    targetOffsetQuarterTones: offsetQuarterTones + 1,
                    isChainStart: chain.isEmpty, isChainEnd: true,
                    startTimeFactor: bend.startTimeFactor,
                    endTimeFactor: bend.endTimeFactor,
                )))
                return chain
            }
            guard let nextIndex = nextSoundingChordIndex(in: voiceElements, after: index),
                  let follower = chainCapableNote(in: voiceElements, at: nextIndex),
                  follower.guitarBendBack
            else { return nil }
            let target = (follower.pitch - basePitch) * 2
            chain.append((index, BendChainSlot(
                basePitch: basePitch,
                startOffsetQuarterTones: offsetQuarterTones,
                targetOffsetQuarterTones: target,
                isChainStart: chain.isEmpty, isChainEnd: false,
                startTimeFactor: bend.startTimeFactor,
                endTimeFactor: bend.endTimeFactor,
            )))
            offsetQuarterTones = target
            index = nextIndex
            if let next = follower.guitarBend, startsChain(next.type) {
                bend = next
                continue
            }
            chain.append((index, BendChainSlot(
                basePitch: basePitch,
                startOffsetQuarterTones: offsetQuarterTones,
                targetOffsetQuarterTones: nil,
                isChainStart: false, isChainEnd: true,
                startTimeFactor: 0, endTimeFactor: 1,
            )))
            return chain
        }
    }

    /// Whether a bend type opens (or extends) a pitch-curving chain in v1.
    /// See `guitarBendChains` for why the other five do not.
    private static func startsChain(_ type: GuitarBendType) -> Bool {
        switch type {
        case .bend, .slightBend: true
        case .preBend, .graceNoteBend, .dive, .preDive, .dip, .scoop: false
        }
    }

    /// `bendChainNote` for the element at `index`, gated on that chord going
    /// through the plain note loop of `renderChordWithGraces`. A tremolo or
    /// arpeggio chord takes a different path that never consults the chain
    /// map, so admitting one would leave a note-on without its note-off.
    /// A muted note (`<play>0</play>`) and a tied one are excluded for the
    /// same reason — see `guitarBendChains` for what a tie costs here.
    private static func chainCapableNote(
        in voiceElements: [VoiceElement], at index: Int,
    ) -> Note? {
        guard index >= 0, index < voiceElements.count,
              case let .chord(chord) = voiceElements[index],
              chord.tremolo == nil, chord.arpeggio == nil,
              let note = bendChainNote(in: chord), note.play,
              note.tieBack == nil, note.tieForward == nil
        else { return nil }
        return note
    }

    /// Index of the next element that actually sounds. Rests are `.chord`
    /// elements with no notes, so they are skipped exactly as
    /// `glissandoEndPitch` skips them.
    private static func nextSoundingChordIndex(
        in voiceElements: [VoiceElement], after index: Int,
    ) -> Int? {
        var i = index + 1
        while i < voiceElements.count {
            if case let .chord(chord) = voiceElements[i], !chord.notes.isEmpty { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Rendering

    /// Wheel value for an offset expressed in quarter tones, at the
    /// 12-semitone sensitivity the track header sets via RPN
    /// (`MidiRenderer+Header.swift`). Same scaling `renderPortamento` uses.
    static func bendWheelValue(quarterTones: Int) -> Int {
        bendWheelValue(semitones: Double(quarterTones) / 2.0)
    }

    private static func bendWheelValue(semitones: Double) -> Int {
        let sensitivity = 12.0
        let offset = max(-8192.0, min(8191.0, semitones / sensitivity * 8191.0))
        return MidiEvent.pitchBendCenter + Int(offset.rounded())
    }

    // swiftlint:disable:next function_parameter_count
    /// Emit one chord's contribution to a bend chain.
    ///
    /// A chain-start slot strikes `basePitch` and emits no note-off; interior
    /// slots emit neither, only wheel traffic; the chain-end slot releases
    /// `basePitch` and resets the wheel. The ramp is confined to the bend's
    /// `[startTimeFactor, endTimeFactor]` window inside this chord and holds
    /// on both sides of it.
    ///
    /// Sampling mirrors `renderPortamento` (`MidiRenderer+Glissando.swift`):
    /// one event every ~16 ticks clamped to [4, 64], and the last wheel event
    /// of the chord lands at `offTick − 1` so a chain-end reset has the whole
    /// `offTick` to itself — otherwise a synth that reorders simultaneous
    /// events by message type can apply the reset BEFORE the peak and leave
    /// the wheel stuck for the rest of the song.
    static func renderBendChainNote(
        note: Note,
        slot: BendChainSlot,
        startTick: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        // A muted note (`<play>0</play>`) emits no MIDI. Mirrors the
        // `if (!note->play()) return;` guard in CompatMidiRender::collectNote.
        // `chainCapableNote` already refuses to build a chain through one, so
        // this is belt and braces.
        guard note.play else { return }
        let velocity = note.customizedVelocity(velocity)
        let offTick = startTick + durationTicks - 1
        let lastSampleTick = max(startTick, offTick - 1)
        if slot.isChainStart {
            events.append(TimedMidiEvent(
                tick: startTick,
                event: .noteOn(channel: channel, pitch: slot.basePitch, velocity: velocity),
            ))
        }
        events.append(TimedMidiEvent(
            tick: startTick,
            event: .pitchBend(
                channel: channel,
                value: bendWheelValue(quarterTones: slot.startOffsetQuarterTones),
            ),
        ))
        if let target = slot.targetOffsetQuarterTones {
            appendBendRamp(
                slot: slot, target: target,
                startTick: startTick, durationTicks: durationTicks,
                lastSampleTick: lastSampleTick,
                channel: channel, events: &events,
            )
        }
        if slot.isChainEnd {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: slot.basePitch, velocity: 0),
            ))
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .pitchBend(channel: channel, value: MidiEvent.pitchBendCenter),
            ))
        }
    }

    // swiftlint:disable:next function_parameter_count
    /// Wheel samples from the slot's start offset to `target`, spread across
    /// the bend's time-factor window and then held to `lastSampleTick`.
    private static func appendBendRamp(
        slot: BendChainSlot,
        target: Int,
        startTick: Int,
        durationTicks: Int,
        lastSampleTick: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        let span = Double(durationTicks)
        let windowEnd = min(
            startTick + Int((span * slot.endTimeFactor).rounded()), lastSampleTick,
        )
        let rampEnd = max(windowEnd, startTick)
        let rampStart = min(
            startTick + Int((span * slot.startTimeFactor).rounded()), rampEnd,
        )
        let rampSpan = rampEnd - rampStart
        let fromSemitones = Double(slot.startOffsetQuarterTones) / 2.0
        let deltaSemitones = Double(target - slot.startOffsetQuarterTones) / 2.0
        let sampleCount = max(4, min(64, durationTicks / 16))
        for i in 1 ... sampleCount {
            let t = Double(i) / Double(sampleCount)
            events.append(TimedMidiEvent(
                tick: rampStart + Int((Double(rampSpan) * t).rounded()),
                event: .pitchBend(
                    channel: channel,
                    value: bendWheelValue(semitones: fromSemitones + deltaSemitones * t),
                ),
            ))
        }
        // A window that closes before the chord does holds the reached offset
        // to the end, so the wheel is unambiguous for the rest of the chord.
        if rampEnd < lastSampleTick {
            events.append(TimedMidiEvent(
                tick: lastSampleTick,
                event: .pitchBend(
                    channel: channel, value: bendWheelValue(quarterTones: target),
                ),
            ))
        }
    }
}
