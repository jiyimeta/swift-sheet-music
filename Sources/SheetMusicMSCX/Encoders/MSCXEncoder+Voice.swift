import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Build the `<voice>` element. Phase 1 supports the element
    /// kinds present in `midi01.mscx`: chords (with rests as
    /// notes-empty chords), key/time/clef changes. Other cases
    /// (Tempo, Dynamic, Spanner, Harmony, …) throw
    /// `SheetMusicError.malformedScore` until follow-up specs add
    /// proper encoders.
    ///
    /// Tuplets are emitted as `<Tuplet>` … `<endTuplet/>` markers
    /// around the elements they cover. Chord/rest durations within
    /// a tuplet are un-scaled (divided by the tuplet ratio) so the
    /// parser's positional re-scaling produces the original
    /// fraction. Nested tuplets are not yet supported and throw.
    func encode() throws -> XMLTreeNode {
        try Self.validateNoNestedTuplets(tuplets)
        let tupletByStart = Dictionary(uniqueKeysWithValues: tuplets.map { ($0.startIndex, $0) })
        let tupletByEnd = Dictionary(uniqueKeysWithValues: tuplets.map { ($0.endIndex, $0) })

        var children: [XMLTreeNode] = []
        for (index, element) in elements.enumerated() {
            if let starting = tupletByStart[index] {
                children.append(starting.encode())
            }
            let activeTuplet = tupletByStart[index]
                ?? tupletByEnd[index]
                ?? tupletContaining(index: index)
            try children.append(encode(element: element, activeTuplet: activeTuplet))
            if tupletByEnd[index] != nil {
                children.append(XMLTreeNode(name: "endTuplet"))
            }
        }
        return XMLTreeNode(name: "voice", children: children)
    }

    private func tupletContaining(index: Int) -> Tuplet? {
        tuplets.first(where: { index >= $0.startIndex && index <= $0.endIndex })
    }

    private static func validateNoNestedTuplets(_ tuplets: [Tuplet]) throws {
        let sorted = tuplets.sorted { $0.startIndex < $1.startIndex }
        for (i, current) in sorted.enumerated() {
            for next in sorted.dropFirst(i + 1) where next.startIndex <= current.endIndex {
                throw SheetMusicError.malformedScore(
                    reason: "Nested or overlapping tuplets not yet "
                        + "supported by MSCXEncoder Phase 2.1 — see "
                        + "docs/superpowers/specs/2026-05-07-mscx-export-design.md"
                )
            }
        }
    }

    private func encode(
        element: VoiceElement, activeTuplet: Tuplet?
    ) throws -> XMLTreeNode {
        switch element {
        case let .chord(chord):
            let unscaled = try unscaledDuration(chord.duration, in: activeTuplet)
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
        case .barLine, .dynamic, .spanner,
             .measureRepeat, .fermata, .staffText, .harmony,
             .rehearsalMark, .locationShift:
            throw SheetMusicError.malformedScore(
                reason: "VoiceElement \(element) not yet supported "
                    + "by MSCXEncoder Phase 1 — see "
                    + "docs/superpowers/specs/2026-05-07-mscx-export-design.md"
            )
        }
    }

    /// Divide the stored (already-scaled) duration by the tuplet's
    /// `actualNotes/normalNotes` ratio so the decoder's positional
    /// scaling reproduces the original fraction.
    private func unscaledDuration(
        _ duration: NoteDuration, in tuplet: Tuplet?
    ) throws -> NoteDuration {
        guard let tuplet else { return duration }
        let scaled = duration.asFraction
        // Decoder scales by normalNotes/actualNotes. To invert:
        // multiply by actualNotes/normalNotes.
        let unscaled = Fraction(
            numerator: scaled.numerator * tuplet.actualNotes,
            denominator: scaled.denominator * tuplet.normalNotes
        )
        let candidate = NoteDuration.fraction(unscaled)
        guard candidate.decomposed() != nil else {
            throw SheetMusicError.malformedScore(
                reason: "Tuplet member duration \(scaled) does not "
                    + "decompose to a named base + dots after "
                    + "un-scaling by \(tuplet.actualNotes)/"
                    + "\(tuplet.normalNotes); MSCXEncoder Phase 2.1 "
                    + "supports only common cases."
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
