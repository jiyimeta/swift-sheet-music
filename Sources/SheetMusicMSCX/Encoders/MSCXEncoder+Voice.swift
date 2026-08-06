import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Build the `<voice>` element.
    ///
    /// Tuplets are emitted as `<Tuplet>` … `<endTuplet/>` markers
    /// around the elements they cover. Chord/rest durations within
    /// a tuplet are un-scaled (divided by the product of every
    /// containing tuplet's ratio) so the parser's positional
    /// re-scaling reproduces the original fraction. Properly
    /// nested tuplets — disjoint or fully containing — are
    /// supported; truly overlapping ranges throw.
    func encode(options: MSCXEncoderOptions = .init()) throws -> XMLTreeNode {
        try encode(carryIn: VoiceTieCarry(), options: options).node
    }

    /// Convenience overload threading drum-staff context: callers that
    /// already know the staff group and voice index can request
    /// percussion-aware emission without pre-building a `VoiceTieCarry`.
    func encode(
        staffGroup: String,
        voiceIndex: Int,
        options: MSCXEncoderOptions = .init(),
    ) throws -> XMLTreeNode {
        try encode(
            carryIn: VoiceTieCarry(),
            options: options,
            staffGroup: staffGroup,
            voiceIndex: voiceIndex,
        ).node
    }

    /// Carry data threaded measure-to-measure for cross-measure tie
    /// location math. `prevChordDuration` is the played duration of
    /// the last chord in the previous measure's voice — used as the
    /// magnitude of a `<prev>` location's negative offset.
    /// `prevVoiceTotal` is that voice's total played duration (= bar
    /// length) — used to compute the source's position-within-its-bar
    /// for `<measures>-1</measures><fractions>P</fractions>` form.
    struct VoiceTieCarry {
        var prevChordDuration: Fraction?
        var prevVoiceTotal: Fraction?

        init(prevChordDuration: Fraction? = nil, prevVoiceTotal: Fraction? = nil) {
            self.prevChordDuration = prevChordDuration
            self.prevVoiceTotal = prevVoiceTotal
        }
    }

    /// Encode the voice with cross-measure tie carry-in. Returns the
    /// encoded `<voice>` plus the carry-out (last chord duration and
    /// total voice played duration) for the next measure.
    ///
    /// `isStaffHead` is true only for voice 0 of measure 0 of a staff.
    /// MuseScore Studio's writer omits the implicit C-major key
    /// signature at the staff head — emitting `<KeySig><concertKey>0
    /// </concertKey></KeySig>` causes Studio to display a redundant
    /// "natural" sign at the start of the system on file open. We
    /// mirror that omission here.
    ///
    /// `systemElements` (typically only non-empty for voice 0) are
    /// interleaved into the chord/rest stream at their natural cursor
    /// positions, matching the document order MuseScore Studio writes.
    /// Elements whose position falls on a chord boundary need no
    /// `<location>` shift — the cursor is already there. Elements whose
    /// position falls past the final chord boundary are emitted with a
    /// trailing forward shift.
    /// `effectiveDuration` is the containing measure's effective
    /// duration (TimeSignature × actualLength). Used to resolve
    /// `.measure` rests and to drive cross-measure tie offsets when
    /// a voice contains a measure-filling rest. The 4/4 default is
    /// a source-compatibility shim for callers that do not yet
    /// supply it; non-`.measure` voices behave identically with or
    /// without the real value, so the default is safe until decoders
    /// start emitting `.measure` rests.
    func encode(
        carryIn: VoiceTieCarry,
        isStaffHead: Bool = false,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
        systemElements: [PositionedSystemElement] = [],
        effectiveDuration: Fraction = Fraction(numerator: 4, denominator: 4),
    ) throws -> (node: XMLTreeNode, carryOut: VoiceTieCarry) {
        try Self.validateProperlyNested(tuplets)
        // At a given startIndex, push outer tuplets (longer range)
        // before inner ones so the close-side LIFO pops innermost first.
        var startsByIndex: [Int: [Tuplet]] = [:]
        for tuplet in tuplets {
            startsByIndex[tuplet.startIndex, default: []].append(tuplet)
        }
        for key in startsByIndex.keys {
            startsByIndex[key]?.sort { $0.endIndex > $1.endIndex }
        }
        var endCountByIndex: [Int: Int] = [:]
        for tuplet in tuplets {
            endCountByIndex[tuplet.endIndex, default: 0] += 1
        }

        // Index of the last chord-bearing element in this voice. A
        // chord at this index whose `tieForward` is set ties into
        // the *next* measure (no further chord follows here), so the
        // forward location gets the `<measures>1</measures>` form
        // instead of `<fractions>chord.duration</fractions>`.
        var lastChordIndex: Int?
        for (i, el) in elements.enumerated() {
            if case .chord = el { lastChordIndex = i }
        }

        let voiceBarLength = resolvedBarLength(effectiveDuration: effectiveDuration)
        // Staff-head suppression of an implicit C-major KeySig: drop
        // the very first VoiceElement when this voice sits at the
        // staff head and that element is `keySignature` with
        // concertKey == 0. Tuplets do not span key signatures, so
        // the open/close tuplet bookkeeping at index 0 is unaffected.
        let dropInitialZeroKeySig = shouldDropInitialZeroKeySig(isStaffHead: isStaffHead)

        var state = EncodeState(carryIn: carryIn)
        let sortedSys = Self.sortedSystemElements(systemElements)
        var sysIdx = Self.emitSystemElementsAtCursor(
            sortedSys, from: 0,
            cursor: state.voiceTotal, into: &state.children,
        )
        let plan = IterationPlan(
            startsByIndex: startsByIndex,
            endCountByIndex: endCountByIndex,
            lastChordIndex: lastChordIndex,
            voiceBarLength: voiceBarLength,
            effectiveDuration: effectiveDuration,
            dropInitialZeroKeySig: dropInitialZeroKeySig,
        )
        for (index, element) in elements.enumerated() {
            try iterate(
                element: element,
                index: index,
                plan: plan,
                carryIn: carryIn,
                state: &state,
                options: options,
                staffGroup: staffGroup,
                voiceIndex: voiceIndex,
            )
            sysIdx = Self.emitSystemElementsAtCursor(
                sortedSys, from: sysIdx,
                cursor: state.voiceTotal, into: &state.children,
            )
        }
        sysIdx = Self.flushRemainingSystemElements(
            sortedSys, from: sysIdx,
            cursor: &state.voiceTotal, into: &state.children,
        )
        return (
            XMLTreeNode(name: "voice", children: state.children),
            VoiceTieCarry(
                prevChordDuration: state.previousChordDuration,
                prevVoiceTotal: state.voiceTotal,
            ),
        )
    }

    /// Per-iteration state of the voice-encoding loop. Bundled so
    /// the loop body can stay below the function-body-length limit
    /// after factoring out `emitElement`.
    struct EncodeState {
        var children: [XMLTreeNode] = []
        var stack: [Tuplet] = []
        var previousChordDuration: Fraction?
        var seenChordInVoice = false
        var voiceTotal = Fraction(numerator: 0, denominator: 1)
        /// Two-chord tremolo (`span == .between`) lives only on the
        /// start chord; emitting it stashes the tremolo here so the
        /// next chord-bearing element can carry its own matching
        /// `<Tremolo>` block (MuseScore's serialized form repeats the
        /// `c8/c16/c32` element on both chords). Cleared on consume.
        var pendingFollowerTremolo: Tremolo?

        init(carryIn: VoiceTieCarry) {
            previousChordDuration = carryIn.prevChordDuration
        }
    }

    private func shouldDropInitialZeroKeySig(isStaffHead: Bool) -> Bool {
        guard isStaffHead, let first = elements.first else { return false }
        if case let .keySignature(key) = first, key.concertKey == 0 {
            return true
        }
        return false
    }

    func emitElement(
        element: VoiceElement,
        index: Int,
        lastChordIndex: Int?,
        voiceBarLength: Fraction,
        effectiveDuration: Fraction,
        carryIn: VoiceTieCarry,
        state: inout EncodeState,
        options: MSCXEncoderOptions,
        staffGroup: String,
        voiceIndex: Int,
    ) throws {
        let isLastChord: Bool = {
            if case .chord = element { return index == lastChordIndex }
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
            options: options,
            staffGroup: staffGroup,
            voiceIndex: voiceIndex,
        ))
        if case let .chord(chord) = element {
            // Resolve `.measure` so `asFraction` cannot trap when
            // accumulating the voice total / previous-chord duration
            // for cross-measure tie offsets.
            let chordFrac = chord.duration
                .resolved(in: effectiveDuration)
                .asFraction
            state.previousChordDuration = chordFrac
            state.seenChordInVoice = true
            // Fraction defines `+` but no `+=`; rewriting as
            // shorthand would not compile.
            // swiftlint:disable:next shorthand_operator
            state.voiceTotal = state.voiceTotal + chordFrac
        }
    }

    /// Encode a lifted `SystemElement` to its MSCX node. Mirrors the
    /// dispatch in `encode(element:…)` for what used to be voice
    /// element cases — the actual per-type encoders are unchanged.
    static func encodeSystem(_ element: SystemElement) -> XMLTreeNode {
        switch element {
        case let .tempo(tempo): return tempo.encode()
        case let .rehearsalMark(rehearsalMark): return rehearsalMark.encode()
        case let .staffText(staffText): return staffText.encode()
        case let .swing(swing): return swing.encode()
        case let .instrumentChange(change): return change.encode()
        }
    }

    private static func validateProperlyNested(_ tuplets: [Tuplet]) throws {
        // A laminar family: every pair is disjoint or fully nested.
        for (i, current) in tuplets.enumerated() {
            for other in tuplets.dropFirst(i + 1) {
                let disjoint = current.endIndex < other.startIndex
                    || other.endIndex < current.startIndex
                let currentContainsOther = current.startIndex <= other.startIndex
                    && current.endIndex >= other.endIndex
                let otherContainsCurrent = other.startIndex <= current.startIndex
                    && other.endIndex >= current.endIndex
                if !(disjoint || currentContainsOther || otherContainsCurrent) {
                    throw SheetMusicError.malformedScore(
                        reason: "Tuplets [\(current.startIndex)..."
                            + "\(current.endIndex)] and [\(other.startIndex)..."
                            + "\(other.endIndex)] overlap without "
                            + "nesting; MSCXEncoder accepts only "
                            + "properly nested or disjoint tuplets.",
                    )
                }
            }
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
            return harmony.encode()
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
