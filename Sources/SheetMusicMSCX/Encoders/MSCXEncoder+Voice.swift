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

    /// Carry data threaded measure-to-measure for cross-measure tie
    /// location math. `prevChordDuration` is the played duration of
    /// the last chord in the previous measure's voice — used as the
    /// magnitude of a `<prev>` location's negative offset.
    /// `prevVoiceTotal` is that voice's total played duration (= bar
    /// length) — used to compute the source's position-within-its-bar
    /// for `<measures>-1</measures><fractions>P</fractions>` form.
    struct VoiceTieCarry: Sendable {
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
    func encode(
        carryIn: VoiceTieCarry,
        isStaffHead: Bool = false,
        options: MSCXEncoderOptions = .init()
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

        let voiceBarLength = computedBarLength()
        // Staff-head suppression of an implicit C-major KeySig: drop
        // the very first VoiceElement when this voice sits at the
        // staff head and that element is `keySignature` with
        // concertKey == 0. Tuplets do not span key signatures, so
        // the open/close tuplet bookkeeping at index 0 is unaffected.
        let dropInitialZeroKeySig = shouldDropInitialZeroKeySig(isStaffHead: isStaffHead)

        var state = EncodeState(carryIn: carryIn)
        for (index, element) in elements.enumerated() {
            for opening in startsByIndex[index] ?? [] {
                state.children.append(opening.encode())
                state.stack.append(opening)
            }
            if !(dropInitialZeroKeySig && index == 0) {
                try emitElement(
                    element: element,
                    index: index,
                    lastChordIndex: lastChordIndex,
                    voiceBarLength: voiceBarLength,
                    carryIn: carryIn,
                    state: &state,
                    options: options
                )
            }
            for _ in 0 ..< (endCountByIndex[index] ?? 0) {
                state.stack.removeLast()
                state.children.append(XMLTreeNode(name: "endTuplet"))
            }
        }
        return (
            XMLTreeNode(name: "voice", children: state.children),
            VoiceTieCarry(
                prevChordDuration: state.previousChordDuration,
                prevVoiceTotal: state.voiceTotal
            )
        )
    }

    /// Per-iteration state of the voice-encoding loop. Bundled so
    /// the loop body can stay below the function-body-length limit
    /// after factoring out `emitElement`.
    private struct EncodeState {
        var children: [XMLTreeNode] = []
        var stack: [Tuplet] = []
        var previousChordDuration: Fraction?
        var seenChordInVoice = false
        var voiceTotal = Fraction(numerator: 0, denominator: 1)

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

    private func emitElement(
        element: VoiceElement,
        index: Int,
        lastChordIndex: Int?,
        voiceBarLength: Fraction,
        carryIn: VoiceTieCarry,
        state: inout EncodeState,
        options: MSCXEncoderOptions
    ) throws {
        let isLastChord: Bool = {
            if case .chord = element { return index == lastChordIndex }
            return false
        }()
        try state.children.append(encode(
            element: element,
            activeTuplets: state.stack,
            previousChordDuration: state.previousChordDuration,
            isFirstChordOfVoice: !state.seenChordInVoice,
            isLastChordOfVoice: isLastChord,
            prevVoiceTotal: carryIn.prevVoiceTotal,
            voiceBarLength: voiceBarLength,
            options: options
        ))
        if case let .chord(chord) = element {
            state.previousChordDuration = chord.duration.asFraction
            state.seenChordInVoice = true
            // Fraction defines `+` but no `+=`; rewriting as
            // shorthand would not compile.
            // swiftlint:disable:next shorthand_operator
            state.voiceTotal = state.voiceTotal + chord.duration.asFraction
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
                            + "properly nested or disjoint tuplets."
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
        options: MSCXEncoderOptions = .init()
    ) throws -> XMLTreeNode {
        switch element {
        case let .chord(chord):
            let unscaled = try unscaledDuration(chord.duration, in: activeTuplets)
            let unscaledChord = Chord(
                duration: unscaled,
                notes: chord.notes,
                arpeggio: chord.arpeggio,
                lyrics: chord.lyrics
            )
            let tieForward = forwardTieLocation(
                chord: chord,
                isLastChordOfVoice: isLastChordOfVoice,
                voiceBarLength: voiceBarLength
            )
            let tieBack = backwardTieLocation(
                chord: chord,
                isFirstChordOfVoice: isFirstChordOfVoice,
                previousChordDuration: previousChordDuration,
                prevVoiceTotal: prevVoiceTotal
            )
            return unscaledChord.notes.isEmpty
                ? unscaledChord.encodeAsRest(options: options)
                : unscaledChord.encodeAsChord(
                    tieForwardLocation: tieForward,
                    tieBackLocation: tieBack,
                    options: options
                )
        case let .keySignature(key):
            return key.encode(options: options)
        case let .timeSignature(time):
            return time.encode()
        case let .clef(clef):
            return clef.encode()
        case let .tempo(tempo):
            return tempo.encode()
        case let .dynamic(dynamic):
            return dynamic.encode()
        case let .barLine(barLine):
            return barLine.encode()
        case let .staffText(staffText):
            return staffText.encode()
        case let .rehearsalMark(rehearsalMark):
            return rehearsalMark.encode()
        case let .harmony(harmony):
            return harmony.encode()
        case let .measureRepeat(measureRepeat):
            return measureRepeat.encode()
        case let .fermata(fermata):
            return fermata.encode()
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
                    text: "\(delta.numerator)/\(delta.denominator)"
                )]
            )
        case let .spanner(spanner):
            return spanner.encode(options: options)
        }
    }

    /// Sum of all played durations in the voice. The cross-measure
    /// forward tie uses this as `barLength` to compute
    /// `<fractions>(source.duration - barLength)</fractions>`,
    /// matching MuseScore's `(measures, fractions)` encoding where
    /// the pair sums to the actual played-tick delta.
    private func computedBarLength() -> Fraction {
        elements.reduce(Fraction(numerator: 0, denominator: 1)) { acc, element in
            if case let .chord(chord) = element {
                return acc + chord.duration.asFraction
            }
            return acc
        }
    }

    /// Build the `<Spanner type="Tie"><next><location>` payload
    /// for a chord with `tieForward` set. MuseScore encodes the
    /// `<location>` as a played-tick delta from source to target,
    /// expressed as `(measures, fractions)` whose sum equals the
    /// delta. For ties to the immediately following chord:
    ///  - same bar: `<fractions>source.duration</fractions>` only
    ///  - cross bar: `<measures>1</measures><fractions>(source.duration - barLength)</fractions>`
    private func forwardTieLocation(
        chord: Chord,
        isLastChordOfVoice: Bool,
        voiceBarLength: Fraction
    ) -> TieLocation? {
        guard chord.notes.contains(where: { $0.tieForward != nil })
        else { return nil }
        let dur = chord.duration.asFraction
        return isLastChordOfVoice
            ? .crossMeasure(measures: 1, fractions: dur - voiceBarLength)
            : .sameMeasure(fractions: dur)
    }

    /// Build the `<Spanner type="Tie"><prev><location>` payload
    /// for a chord with `tieBack` set. Mirrors `forwardTieLocation`
    /// — same-bar back ties carry `-prev_chord_duration`;
    /// cross-bar back ties carry `(measures: -1, fractions: prev_voice_total - prev_chord_duration)`.
    private func backwardTieLocation(
        chord: Chord,
        isFirstChordOfVoice: Bool,
        previousChordDuration: Fraction?,
        prevVoiceTotal: Fraction?
    ) -> TieLocation? {
        guard chord.notes.contains(where: { $0.tieBack != nil }),
              let prevDur = previousChordDuration
        else { return nil }
        if isFirstChordOfVoice, let prevTotal = prevVoiceTotal {
            return .crossMeasure(measures: -1, fractions: prevTotal - prevDur)
        }
        return .sameMeasure(fractions: Fraction(
            numerator: -prevDur.numerator,
            denominator: prevDur.denominator
        ))
    }

    /// Divide the stored (already-scaled) duration by the product
    /// of every containing tuplet's `actualNotes/normalNotes` ratio
    /// so the decoder's positional scaling reproduces the original
    /// fraction.
    private func unscaledDuration(
        _ duration: NoteDuration, in tuplets: [Tuplet]
    ) throws -> NoteDuration {
        guard !tuplets.isEmpty else { return duration }
        let scaled = duration.asFraction
        // Decoder scales by ∏ normalNotes/actualNotes. To invert:
        // multiply by ∏ actualNotes/normalNotes.
        var unscaled = scaled
        for tuplet in tuplets {
            unscaled = Fraction(
                numerator: unscaled.numerator * tuplet.actualNotes,
                denominator: unscaled.denominator * tuplet.normalNotes
            )
        }
        let candidate = NoteDuration.fraction(unscaled)
        guard candidate.decomposed() != nil else {
            let ratios = tuplets
                .map { "\($0.actualNotes)/\($0.normalNotes)" }
                .joined(separator: " × ")
            throw SheetMusicError.malformedScore(
                reason: "Tuplet member duration \(scaled) does not "
                    + "decompose to a named base + dots after "
                    + "un-scaling by \(ratios); MSCXEncoder supports "
                    + "only durations representable as base + dots."
            )
        }
        return candidate
    }
}

extension Tuplet {
    /// Build the `<Tuplet>` opening marker.
    func encode() -> XMLTreeNode {
        XMLTreeNode(
            name: "Tuplet",
            children: [
                XMLTreeNode(name: "normalNotes", text: String(normalNotes)),
                XMLTreeNode(name: "actualNotes", text: String(actualNotes)),
            ]
        )
    }
}
