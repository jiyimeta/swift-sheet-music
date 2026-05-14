import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Append lifted system elements at the head of the voice with
    /// `<location>` shifts matching their `MeasurePosition`. Sorted
    /// by position so multi-element measures emit in time order.
    /// Each shift is consumed by the immediately-following system
    /// element only — chords later in the voice remain at their
    /// natural cursor.
    func injectSystemElements(
        _ systemElements: [PositionedSystemElement],
        into state: inout EncodeState,
    ) {
        let sorted = systemElements.sorted { $0.position < $1.position }
        for sysElement in sorted {
            let offset = sysElement.position.offset
            if offset.numerator != 0 {
                state.children.append(XMLTreeNode(
                    name: "location",
                    children: [XMLTreeNode(
                        name: "fractions",
                        text: "\(offset.numerator)/\(offset.denominator)",
                    )],
                ))
            }
            state.children.append(Self.encodeSystem(sysElement.element))
        }
    }

    /// Bar length to use for cross-measure tie offsets. A voice
    /// carrying a `.measure` rest cannot be summed element-by-element
    /// (the rest's `asFraction` would trap), so we substitute the
    /// containing measure's effective duration. Voices without
    /// `.measure` keep the historical sum-based path so tests
    /// authored against pre-`.measure` fixtures continue to
    /// round-trip byte-identically.
    func resolvedBarLength(effectiveDuration: Fraction) -> Fraction {
        elements.contains(where: \.isMeasureRest)
            ? effectiveDuration
            : computedBarLength()
    }

    /// Sum of all played durations in the voice. The cross-measure
    /// forward tie uses this as `barLength` to compute
    /// `<fractions>(source.duration - barLength)</fractions>`,
    /// matching MuseScore's `(measures, fractions)` encoding where
    /// the pair sums to the actual played-tick delta.
    func computedBarLength() -> Fraction {
        elements.reduce(Fraction(numerator: 0, denominator: 1)) { acc, element in
            if case let .chord(chord) = element {
                // `.measure` chords cannot be summed (they carry no
                // intrinsic duration); the caller substitutes the
                // measure's effective duration in `voiceBarLength`
                // instead. Defensive guard — primary path skips
                // `computedBarLength` entirely when a measure-rest
                // is present.
                if case .measure = chord.duration { return acc }
                return acc + chord.duration.asFraction
            }
            return acc
        }
    }

    /// Resolve the "written" duration of the tuplet's first member
    /// for emission as `<baseNote>{name}</baseNote>`. Returns nil for
    /// degenerate tuplets (empty range or non-chord/rest member) and
    /// for durations that cannot be expressed as a named base.
    func tupletBaseDuration(
        opening: Tuplet,
        activeTuplets: [Tuplet],
    ) -> NoteDuration? {
        guard opening.startIndex < elements.count else { return nil }
        guard case let .chord(chord) = elements[opening.startIndex] else {
            return nil
        }
        return try? unscaledDuration(chord.duration, in: activeTuplets)
    }

    /// Divide the stored (already-scaled) duration by the product
    /// of every containing tuplet's `actualNotes/normalNotes` ratio
    /// so the decoder's positional scaling reproduces the original
    /// fraction.
    func unscaledDuration(
        _ duration: NoteDuration, in tuplets: [Tuplet],
    ) throws -> NoteDuration {
        guard !tuplets.isEmpty else { return duration }
        // A `.measure` rest is never inside a tuplet; bail before
        // touching `asFraction` for trap safety.
        if case .measure = duration { return duration }
        let scaled = duration.asFraction
        // Decoder scales by ∏ normalNotes/actualNotes. To invert:
        // multiply by ∏ actualNotes/normalNotes.
        var unscaled = scaled
        for tuplet in tuplets {
            unscaled = Fraction(
                numerator: unscaled.numerator * tuplet.actualNotes,
                denominator: unscaled.denominator * tuplet.normalNotes,
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
                    + "only durations representable as base + dots.",
            )
        }
        return candidate
    }
}
