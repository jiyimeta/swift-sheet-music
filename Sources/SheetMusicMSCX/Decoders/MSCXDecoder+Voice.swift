// swiftlint:disable function_body_length file_length
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    private struct OpenTuplet {
        let ratio: Fraction
        let firstElementIndex: Int
    }

    static func decode(_ node: XMLTreeNode) throws -> Voice {
        var elements: [VoiceElement] = []
        elements.reserveCapacity(node.children.count)
        var tuplets: [Tuplet] = []
        // Stack of open tuplet ratios (normal/actual). Each <Tuplet>
        // pushes, each <endTuplet/> pops. Chord/Rest durations are
        // scaled by the product of every ratio on the stack — mirrors
        // MuseScore's positional state machine in
        // MeasureRead::readVoice. `firstElementIndex` records where
        // the tuplet's first member landed so we can finalise a
        // `Tuplet` range at `<endTuplet>`.
        var tupletStack: [OpenTuplet] = []
        // Buffer for `<Chord><acciaccatura/>...` etc. encountered
        // before the next ordinary chord in this voice. Cleared
        // whenever attached to the next main `Chord`. Stranded
        // entries (left over at end-of-voice) are dropped — MuseScore
        // doesn't play them either.
        var pendingGracesBefore: [GraceChord] = []
        func tupletFractions() -> [Fraction] {
            tupletStack.map(\.ratio)
        }
        for child in node.children {
            switch child.name {
            case "Chord":
                if let graceType = Chord.graceType(in: child) {
                    // Decode shape but do NOT scale by tuplet ratios:
                    // graces don't consume tuplet time — see
                    // CompatMidiRender::renderGraceNotesBefore.
                    let inner = try Chord.decode(child)
                    let g = GraceChord(
                        graceType: graceType,
                        duration: inner.duration,
                        notes: inner.notes
                    )
                    if graceType.isAfter {
                        // Attach to the most recently emitted chord.
                        // Walk backwards because tempo / dynamic /
                        // location elements may sit between the
                        // grace and its parent chord.
                        for i in stride(from: elements.count - 1, through: 0, by: -1) {
                            if case var .chord(parent) = elements[i] {
                                parent.graceNotesAfter.append(g)
                                elements[i] = .chord(parent)
                                break
                            }
                        }
                        // No preceding chord → drop silently.
                    } else {
                        pendingGracesBefore.append(g)
                    }
                    continue
                }
                var chord = try Chord.decode(child)
                chord.duration = scaled(
                    chord.duration, by: tupletFractions()
                )
                if !pendingGracesBefore.isEmpty {
                    chord.graceNotesBefore = pendingGracesBefore
                    pendingGracesBefore.removeAll(keepingCapacity: true)
                }
                elements.append(.chord(chord))
            case "Rest":
                var rest = try MSCXRestDecoder.decode(child)
                rest.duration = scaled(
                    rest.duration, by: tupletFractions()
                )
                elements.append(.chord(rest))
            case "Tuplet":
                if let ratio = tupletRatio(from: child) {
                    tupletStack.append(OpenTuplet(
                        ratio: ratio,
                        firstElementIndex: elements.count
                    ))
                }
            case "endTuplet":
                if let top = tupletStack.popLast() {
                    let endIndex = elements.count - 1
                    if endIndex >= top.firstElementIndex {
                        tuplets.append(Tuplet(
                            normalNotes: top.ratio.numerator,
                            actualNotes: top.ratio.denominator,
                            startIndex: top.firstElementIndex,
                            endIndex: endIndex
                        ))
                    }
                }
            case "KeySig":
                try elements.append(.keySignature(KeySignature.decode(child)))
            case "TimeSig":
                try elements.append(.timeSignature(TimeSignature.decode(child)))
            case "Clef":
                try elements.append(.clef(Clef.decode(child)))
            case "BarLine":
                try elements.append(.barLine(BarLine.decode(child)))
            case "Tempo":
                try elements.append(.tempo(Tempo.decode(child)))
            case "Dynamic":
                try elements.append(.dynamic(Dynamic.decode(child)))
            case "Spanner":
                try elements.append(.spanner(Spanner.decode(child)))
            case "MeasureRepeat", "RepeatMeasure":
                // <RepeatMeasure> is the MuseScore 3.x spelling of the same
                // element (see MeasureRead::readVoice in measureread.cpp:336).
                try elements.append(.measureRepeat(MeasureRepeat.decode(child)))
            case "Fermata":
                let subtype = child.first("subtype")?.text ?? ""
                elements.append(.fermata(Fermata(subtype: subtype)))
            case "StaffText":
                try elements.append(.staffText(
                    StaffText.decode(child, isSystemText: false)))
            case "SystemText":
                try elements.append(.staffText(
                    StaffText.decode(child, isSystemText: true)))
            case "Harmony":
                try elements.append(.harmony(Harmony.decode(child)))
            case "RehearsalMark":
                try elements.append(.rehearsalMark(
                    RehearsalMark.decode(child)))
            case "location":
                // Voice-level cursor shift. MuseScore uses
                // `<location><fractions>N/D</fractions></location>`
                // to attach the next non-temporal element (system /
                // staff text, dynamic, tempo, rehearsal mark) at a
                // tick that doesn't fall on a chord boundary. The
                // shift is relative to the current cursor; negative
                // values jog backwards. `<measures>` only appears in
                // spanner contexts and is ignored here.
                if let fracText = child.first("fractions")?.text,
                   let frac = Fraction(mscxString: fracText)
                {
                    elements.append(.locationShift(delta: frac))
                }
            default:
                // Unknown elements are silently ignored. Decoder is permissive on purpose
                // — once we see what features individual MIDI tests actually need, they
                // can be promoted to first-class VoiceElement cases.
                continue
            }
        }
        // Stranded `pendingGracesBefore` (no following chord in this
        // voice) intentionally dropped — see comment on the buffer.
        return Voice(elements: elements, tuplets: tuplets)
    }

    /// Parse a `<Tuplet>` element's ratio (normalNotes/actualNotes). A triplet's
    /// 3 notes occupy the time of 2 normal notes, so the scale is 2/3.
    private static func tupletRatio(from node: XMLTreeNode) -> Fraction? {
        guard let normalText = node.first("normalNotes")?.text,
              let actualText = node.first("actualNotes")?.text,
              let normal = Int(normalText),
              let actual = Int(actualText),
              normal > 0, actual > 0
        else {
            return nil
        }
        return Fraction(numerator: normal, denominator: actual)
    }

    private static func scaled(_ duration: NoteDuration, by tupletStack: [Fraction]) -> NoteDuration {
        guard !tupletStack.isEmpty else { return duration }
        var frac = duration.asFraction
        for ratio in tupletStack {
            frac = Fraction(
                numerator: frac.numerator * ratio.numerator,
                denominator: frac.denominator * ratio.denominator
            )
        }
        return .fraction(frac)
    }
}
