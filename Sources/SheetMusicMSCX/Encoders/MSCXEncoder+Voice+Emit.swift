import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Voice {
    /// Emit a chord's grace chords into the voice stream.
    ///
    /// Grace chords are siblings of the parent `<Chord>`, not children
    /// of it — see `GraceChord.encode`. *Every* grace goes ahead of its
    /// parent, after-graces included, in the single file order
    /// `Chord.mscxFileOrderedGraces` defines; MuseScore's reader
    /// attaches the whole run to the next normal chord and splits it by
    /// grace-type tag, never by file position. They carry their own
    /// duration and are never folded into the voice-total /
    /// previous-chord-duration bookkeeping: graces don't consume voice
    /// time, mirroring the decoder's `pendingGraces` buffer, which is
    /// likewise kept off `Voice.elements` and its cursor advance.
    ///
    /// A grace whose tie leaves the parent chord needs the parent's own
    /// neighbour-chord delta — the grace shares the parent's tick, so
    /// the two are the same value. The unguarded `…Delta` forms are
    /// used because the parent chord itself need not carry any tie.
    private func emitGraceChords(
        of chord: Chord,
        isLastChord: Bool,
        voiceBarLength: Fraction,
        carryIn: VoiceTieCarry,
        state: inout EncodeState,
        options: MSCXEncoderOptions,
    ) {
        guard !(chord.graceNotesBefore.isEmpty && chord.graceNotesAfter.isEmpty)
        else { return }
        let forwardDelta = forwardTieDelta(
            chord: chord,
            isLastChordOfVoice: isLastChord,
            voiceBarLength: voiceBarLength,
        )
        let backwardDelta = backwardTieDelta(
            isFirstChordOfVoice: !state.seenChordInVoice,
            previousChordDuration: state.previousChordDuration,
            prevVoiceTotal: carryIn.prevVoiceTotal,
        )
        for (grace, listIndex) in chord.mscxFileOrderedGracesWithListIndex {
            state.children.append(grace.encode(
                parentChord: chord,
                parentForwardTieLocation: forwardDelta,
                parentBackwardTieLocation: backwardDelta,
                listIndex: listIndex,
                options: options,
            ))
        }
    }

    /// Map each chord-bearing element index to the note list of the
    /// chord a forward tie from there would land on: the next
    /// chord-bearing element in this voice, or — for the last one —
    /// `nextMeasureFirstChordNotes`, the first chord of this voice in
    /// the following measure. Mirrors exactly which chord
    /// `forwardTieLocation` computes its delta towards, so both halves
    /// of a `<location>` always describe the same partner.
    static func forwardTiePartnerNotes(
        in elements: [VoiceElement],
        nextMeasureFirstChordNotes: ChordNotes?,
    ) -> [Int: ChordNotes] {
        var result: [Int: ChordNotes] = [:]
        var pending = nextMeasureFirstChordNotes
        for index in elements.indices.reversed() {
            guard case let .chord(chord) = elements[index] else { continue }
            if let pending { result[index] = pending }
            pending = chord.notes
        }
        return result
    }

    func emitElement(
        element: VoiceElement,
        index: Int,
        plan: IterationPlan,
        carryIn: VoiceTieCarry,
        state: inout EncodeState,
        options: MSCXEncoderOptions,
        staffGroup: String,
        voiceIndex: Int,
    ) throws {
        let voiceBarLength = plan.voiceBarLength
        let effectiveDuration = plan.effectiveDuration
        let isLastChord: Bool = {
            if case .chord = element { return index == plan.lastChordIndex }
            return false
        }()
        // Consume any pending follower tremolo from the previous start
        // chord — only chord-bearing elements claim it; rests pass
        // through. If the current chord is itself a `.between` start,
        // stash its tremolo for the next chord-bearing element.
        var injectedTremolo: Tremolo?
        if case let .chord(chord) = element, !chord.notes.isEmpty {
            injectedTremolo = state.pendingFollowerTremolo
            state.pendingFollowerTremolo = nil
            if let trem = chord.tremolo, trem.span == .between {
                state.pendingFollowerTremolo = trem
            }
        }
        if case let .chord(chord) = element {
            emitGraceChords(
                of: chord,
                isLastChord: isLastChord,
                voiceBarLength: voiceBarLength,
                carryIn: carryIn,
                state: &state,
                options: options,
            )
        }
        // The chord's own position within the measure, read before the
        // cursor advances past it: both halves of the chord-anchored slur
        // bookkeeping — the end markers landing here and the begin sides
        // registering their targets — are measured from it.
        let chordPosition = state.voiceTotal
        let slurEndMarkers = state.claimSlurEndMarkers(
            forChordRest: element, at: chordPosition, options: options,
        )
        try state.children.append(encode(
            element: element,
            activeTuplets: state.stack,
            previousChordDuration: state.previousChordDuration,
            isFirstChordOfVoice: !state.seenChordInVoice,
            isLastChordOfVoice: isLastChord,
            prevVoiceTotal: carryIn.prevVoiceTotal,
            voiceBarLength: voiceBarLength,
            effectiveDuration: effectiveDuration,
            injectedTremolo: injectedTremolo,
            previousChordNotes: state.previousChordNotes,
            forwardTiePartnerNotes: plan.forwardTiePartnerNotes[index],
            previousChordTrailingBendGrace: state.previousChordTrailingBendGrace,
            slurEndMarkers: slurEndMarkers,
            options: options,
            staffGroup: staffGroup,
            voiceIndex: voiceIndex,
        ))
        if case let .chord(chord) = element {
            // Register the end targets of the begin sides this chord/rest
            // carries, so a later chord in this voice can claim them.
            state.pendingSlurEnds.append(
                contentsOf: chord.pendingSlurEnds(at: chordPosition),
            )
            // Resolve `.measure` so `asFraction` cannot trap when
            // accumulating the voice total / previous-chord duration
            // for cross-measure tie offsets.
            let chordFrac = chord.duration
                .resolved(in: effectiveDuration)
                .asFraction
            state.previousChordDuration = chordFrac
            state.previousChordNotes = chord.notes
            state.previousChordTrailingBendGrace = chord.mscxTrailingAfterGraceBendIndex
            state.seenChordInVoice = true
            // Fraction defines `+` but no `+=`; rewriting as
            // shorthand would not compile.
            // swiftlint:disable:next shorthand_operator
            state.voiceTotal = state.voiceTotal + chordFrac
        }
    }

    private func encode(
        element: VoiceElement,
        activeTuplets: [Tuplet],
        previousChordDuration: Fraction?,
        isFirstChordOfVoice: Bool,
        isLastChordOfVoice: Bool,
        prevVoiceTotal: Fraction?,
        voiceBarLength: Fraction,
        effectiveDuration: Fraction,
        injectedTremolo: Tremolo? = nil,
        previousChordNotes: ChordNotes? = nil,
        forwardTiePartnerNotes: ChordNotes? = nil,
        previousChordTrailingBendGrace: Int? = nil,
        slurEndMarkers: [XMLTreeNode] = [],
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
    ) throws -> XMLTreeNode {
        switch element {
        case let .chord(chord):
            return try encodeChord(
                chord: chord,
                activeTuplets: activeTuplets,
                previousChordDuration: previousChordDuration,
                isFirstChordOfVoice: isFirstChordOfVoice,
                isLastChordOfVoice: isLastChordOfVoice,
                prevVoiceTotal: prevVoiceTotal,
                voiceBarLength: voiceBarLength,
                effectiveDuration: effectiveDuration,
                injectedTremolo: injectedTremolo,
                previousChordNotes: previousChordNotes,
                forwardTiePartnerNotes: forwardTiePartnerNotes,
                previousChordTrailingBendGrace: previousChordTrailingBendGrace,
                slurEndMarkers: slurEndMarkers,
                options: options,
                staffGroup: staffGroup,
                voiceIndex: voiceIndex,
            )
        case let .keySignature(key):
            return key.encode(options: options)
        case let .timeSignature(time):
            return time.encode()
        case let .clef(clef):
            return clef.encode()
        case let .dynamic(dynamic):
            return dynamic.encode()
        case let .barLine(barLine):
            return barLine.encode()
        case let .harmony(harmony):
            return harmony.encode(options: options)
        case let .measureRepeat(measureRepeat):
            return measureRepeat.encode(options: options, in: effectiveDuration)
        case let .fermata(fermata):
            return fermata.encode()
        case let .breath(breath):
            return breath.encode()
        case let .locationShift(delta):
            // Inverse of the inline `<location>` decode: the
            // voice-level cursor shift is `<location><fractions>N/D
            // </fractions></location>`. Negative numerators jog
            // backwards so the next non-temporal element attaches at
            // a sub-chord tick offset.
            return XMLTreeNode(
                name: "location",
                children: [XMLTreeNode(
                    name: "fractions",
                    text: "\(delta.numerator)/\(delta.denominator)",
                )],
            )
        case let .spanner(spanner):
            return spanner.encode(options: options)
        }
    }
}
