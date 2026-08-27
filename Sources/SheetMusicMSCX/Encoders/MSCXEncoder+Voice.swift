import SheetMusicCore
import SheetMusicFoundation
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
    /// `prevChordNotes` is that chord's note list, which the `<notes>`
    /// half of a backward tie's `<location>` is measured against — see
    /// `TieEndpoint`.
    /// `prevChordTrailingBendGrace` is that chord's
    /// `mscxTrailingAfterGraceBendIndex` — the `<grace>` ordinal a guitar
    /// bend's `<prev>` needs when the bend started on the previous chord's
    /// last after-grace rather than on the chord itself.
    struct VoiceTieCarry {
        var prevChordDuration: Fraction?
        var prevVoiceTotal: Fraction?
        var prevChordNotes: ChordNotes?
        var prevChordTrailingBendGrace: Int?

        init(
            prevChordDuration: Fraction? = nil,
            prevVoiceTotal: Fraction? = nil,
            prevChordNotes: ChordNotes? = nil,
            prevChordTrailingBendGrace: Int? = nil,
        ) {
            self.prevChordDuration = prevChordDuration
            self.prevVoiceTotal = prevVoiceTotal
            self.prevChordNotes = prevChordNotes
            self.prevChordTrailingBendGrace = prevChordTrailingBendGrace
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
    /// a source-compatibility shim for callers that do not
    /// supply it; non-`.measure` voices behave identically with or
    /// without the real value, but callers encoding voices that
    /// contain `.measure` rests must supply the effective duration.
    func encode(
        carryIn: VoiceTieCarry,
        isStaffHead: Bool = false,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
        systemElements: [PositionedSystemElement] = [],
        effectiveDuration: Fraction = Fraction(numerator: 4, denominator: 4),
        nextMeasureFirstChordNotes: ChordNotes? = nil,
    ) throws -> (node: XMLTreeNode, carryOut: VoiceTieCarry) {
        try Self.validateProperlyNested(tuplets)
        let plan = makeIterationPlan(
            isStaffHead: isStaffHead,
            effectiveDuration: effectiveDuration,
            nextMeasureFirstChordNotes: nextMeasureFirstChordNotes,
        )
        var state = EncodeState(carryIn: carryIn)
        let sortedSys = Self.sortedSystemElements(systemElements)
        var sysIdx = Self.emitSystemElementsAtCursor(
            sortedSys, from: 0,
            cursor: state.voiceTotal, into: &state.children, options: options,
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
                cursor: state.voiceTotal, into: &state.children, options: options,
            )
        }
        sysIdx = Self.flushRemainingSystemElements(
            sortedSys, from: sysIdx,
            cursor: &state.voiceTotal, into: &state.children, options: options,
        )
        return (
            XMLTreeNode(name: "voice", children: state.children),
            VoiceTieCarry(
                prevChordDuration: state.previousChordDuration,
                prevVoiceTotal: state.voiceTotal,
                prevChordNotes: state.previousChordNotes,
                prevChordTrailingBendGrace: state.previousChordTrailingBendGrace,
            ),
        )
    }

    /// Everything the encode loop needs that doesn't change between
    /// iterations: the tuplet open/close indices, the last chord's
    /// index, the bar length, and the forward-tie partner map.
    private func makeIterationPlan(
        isStaffHead: Bool,
        effectiveDuration: Fraction,
        nextMeasureFirstChordNotes: ChordNotes?,
    ) -> IterationPlan {
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
        return IterationPlan(
            startsByIndex: startsByIndex,
            endCountByIndex: endCountByIndex,
            lastChordIndex: lastChordIndex,
            voiceBarLength: resolvedBarLength(effectiveDuration: effectiveDuration),
            effectiveDuration: effectiveDuration,
            // Staff-head suppression of an implicit C-major KeySig: drop
            // the very first VoiceElement when this voice sits at the
            // staff head and that element is `keySignature` with
            // concertKey == 0. Tuplets do not span key signatures, so
            // the open/close tuplet bookkeeping at index 0 is unaffected.
            dropInitialZeroKeySig: shouldDropInitialZeroKeySig(
                isStaffHead: isStaffHead,
            ),
            forwardTiePartnerNotes: Self.forwardTiePartnerNotes(
                in: elements,
                nextMeasureFirstChordNotes: nextMeasureFirstChordNotes,
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
        /// The note list of the same chord `previousChordDuration`
        /// measures — the partner a backward tie's `<notes>` delta is
        /// taken against.
        var previousChordNotes: ChordNotes?
        /// The `<grace>` ordinal of that same chord's last after-grace when it
        /// begins a guitar bend — see `VoiceTieCarry`.
        var previousChordTrailingBendGrace: Int?
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
            previousChordNotes = carryIn.prevChordNotes
            previousChordTrailingBendGrace = carryIn.prevChordTrailingBendGrace
        }
    }

    private func shouldDropInitialZeroKeySig(isStaffHead: Bool) -> Bool {
        guard isStaffHead, let first = elements.first else { return false }
        if case let .keySignature(key) = first, key.concertKey == 0 {
            return true
        }
        return false
    }

    /// Encode a lifted `SystemElement` to its MSCX node. Mirrors the
    /// dispatch in `encode(element:…)` for what used to be voice
    /// element cases — the actual per-type encoders are unchanged.
    static func encodeSystem(
        _ element: SystemElement,
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        switch element {
        case let .tempo(tempo): return tempo.encode()
        case let .rehearsalMark(rehearsalMark): return rehearsalMark.encode()
        case let .staffText(staffText): return staffText.encode()
        case let .swing(swing): return swing.encode()
        case let .instrumentChange(change): return change.encode(options: options)
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
                        ScoreFault(
                            code: "mscx.encoder.tupletsOverlap",
                            message: "Tuplets [\(current.startIndex)..."
                                + "\(current.endIndex)] and [\(other.startIndex)..."
                                + "\(other.endIndex)] overlap without "
                                + "nesting; MSCXEncoder accepts only "
                                + "properly nested or disjoint tuplets.",
                            location: "\(current.startIndex)...\(current.endIndex)",
                        ),
                    )
                }
            }
        }
    }
}
