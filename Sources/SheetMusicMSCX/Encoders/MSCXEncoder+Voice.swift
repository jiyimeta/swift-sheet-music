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
    func encode() throws -> XMLTreeNode {
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

        var children: [XMLTreeNode] = []
        var stack: [Tuplet] = []
        for (index, element) in elements.enumerated() {
            for opening in startsByIndex[index] ?? [] {
                children.append(opening.encode())
                stack.append(opening)
            }
            try children.append(encode(element: element, activeTuplets: stack))
            for _ in 0 ..< (endCountByIndex[index] ?? 0) {
                stack.removeLast()
                children.append(XMLTreeNode(name: "endTuplet"))
            }
        }
        return XMLTreeNode(name: "voice", children: children)
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
        element: VoiceElement, activeTuplets: [Tuplet]
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
            return unscaledChord.notes.isEmpty
                ? unscaledChord.encodeAsRest()
                : unscaledChord.encodeAsChord()
        case let .keySignature(key):
            return key.encode()
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
            return spanner.encode()
        }
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
