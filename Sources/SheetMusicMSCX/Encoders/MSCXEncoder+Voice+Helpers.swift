import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Sort lifted system elements by position. Encoder uses the
    /// sorted array as a queue, draining elements as the voice
    /// cursor catches up to each position.
    static func sortedSystemElements(
        _ systemElements: [PositionedSystemElement],
    ) -> [PositionedSystemElement] {
        systemElements.sorted { $0.position < $1.position }
    }

    /// Emit any sorted system elements whose position equals the
    /// current cursor. Returns the index of the first element not
    /// yet emitted. The voice encoder calls this before the loop
    /// (to flush position-0 elements) and after each chord/rest
    /// emission (to flush elements landing on each chord boundary).
    /// MuseScore emits system elements inline at their natural
    /// document position — no `<location>` shift is needed when the
    /// cursor is already there.
    static func emitSystemElementsAtCursor(
        _ sorted: [PositionedSystemElement],
        from start: Int,
        cursor: Fraction,
        into children: inout [XMLTreeNode],
        options: MSCXEncoderOptions = .init(),
    ) -> Int {
        var i = start
        while i < sorted.count, sorted[i].position.offset == cursor {
            children.append(Self.encodeSystem(sorted[i].element, options: options))
            i += 1
        }
        return i
    }

    /// Emit any remaining system elements past the final cursor
    /// (positions strictly greater than every chord/rest boundary
    /// in the voice, or off-boundary positions the per-iteration
    /// emit missed). Forward `<location>` shifts walk the cursor
    /// to each target. No compensating back-shift is needed — no
    /// voice content follows.
    static func flushRemainingSystemElements(
        _ sorted: [PositionedSystemElement],
        from start: Int,
        cursor: inout Fraction,
        into children: inout [XMLTreeNode],
        options: MSCXEncoderOptions = .init(),
    ) -> Int {
        var i = start
        while i < sorted.count {
            let target = sorted[i].position.offset
            let delta = target - cursor
            if delta.numerator != 0 {
                children.append(locationNode(delta))
            }
            children.append(Self.encodeSystem(sorted[i].element, options: options))
            cursor = target
            i += 1
        }
        return i
    }

    static func locationNode(_ delta: Fraction) -> XMLTreeNode {
        XMLTreeNode(
            name: "location",
            children: [XMLTreeNode(
                name: "fractions",
                text: "\(delta.numerator)/\(delta.denominator)",
            )],
        )
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
