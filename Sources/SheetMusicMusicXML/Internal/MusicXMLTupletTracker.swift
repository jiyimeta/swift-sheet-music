import SheetMusicCore
import SheetMusicFoundation

/// Groups one voice's chords and rests in one measure into tuplets the way MuseScore's MusicXML import does. A tuplet
/// starts at a `<tuplet type="start">` or, without one, at the first note whose time is modified. It stops at a
/// `<tuplet type="stop">`, before a note whose time is not modified, before another start, and — when no mark started
/// it — once its notes fill it. The measure's end stops one still open. A tuplet stopped short of full is padded with a
/// rest, which the caller places and moves its clock past. C++: `MusicXmlTupletState::determineTupletAction`
/// (`musicxmltupletstate.cpp`), driven by `MusicXmlParserPass2::note` and `resetTuplets` (`importmusicxmlpass2.cpp`).
///
/// One difference: a note whose ratio differs from the open tuplet's stops it and starts its own, where MuseScore
/// would count it into the open one, because a `Tuplet` has one ratio for all its members.
struct MusicXMLTupletTracker {
    private(set) var tuplets: [Tuplet] = []
    private var open: OpenTuplet?

    private struct OpenTuplet {
        let normalNotes: Int
        let actualNotes: Int
        /// A `<tuplet type="start">` opened it, so only a stop closes it, never its being full.
        let marked: Bool
        let appearance: TupletAppearance
        let first: Int
        var last: Int
        var written: Fraction
        var unit: Fraction

        /// The members add up to `actualNotes` of `<normal-type>`, or without one, of the smallest value among them.
        func isFull(normalType: Fraction?) -> Bool {
            let need = MusicXMLTupletNote.scaled(normalType ?? unit, by: actualNotes, over: 1)
            return !written.precedes(need)
        }

        /// The rest that would complete it, from how long its members last.
        var padding: Fraction {
            MusicXMLTupletTracker.padding(after: MusicXMLTupletNote.scaled(written, by: normalNotes, over: actualNotes))
        }
    }

    /// Before `note` joins the voice: stops the open tuplet when `note` cannot continue it — a note whose time is not
    /// modified, a tremolo, a start mark or another ratio. Returns the rest that pads the stopped tuplet when it was
    /// not full (MuseScore's `missingPrev`), or zero; a tremolo stops it unpadded, as `handleTupletStop` alone does
    /// there.
    mutating func stop(before note: MusicXMLTupletNote) -> Fraction {
        guard let current = open,
              !note.isTupletMember || note.mark == .start
              || current.normalNotes != note.normalNotes || current.actualNotes != note.actualNotes
        else { return .zeroTick }
        close()
        return note.isTremolo || current.isFull(normalType: note.normalType) ? .zeroTick : current.padding
    }

    /// Takes the chord or rest at `index`, once `stop(before:)` has seen it. Returns the rest that pads the tuplet when
    /// its stop mark ends it before it is full (MuseScore's `missingCurr`, for more actual notes than normal), or zero.
    mutating func add(_ note: MusicXMLTupletNote, at index: Int) -> Fraction {
        guard note.isTupletMember else { return .zeroTick }
        var current = open ?? OpenTuplet(
            normalNotes: note.normalNotes, actualNotes: note.actualNotes, marked: note.mark == .start,
            appearance: note.appearance, first: index, last: index, written: .zeroTick, unit: note.unit,
        )
        current.last = index
        current.written += note.written
        if note.unit.precedes(current.unit) { current.unit = note.unit }
        open = current
        let full = current.isFull(normalType: note.normalType)
        guard note.mark == .stop || (!current.marked && full) else { return .zeroTick }
        close()
        return current.actualNotes > current.normalNotes && !full ? current.padding : .zeroTick
    }

    /// Stops the tuplet still open at the measure's end. Returns the rest that pads it (`resetTuplets`), or zero.
    mutating func finish() -> Fraction {
        guard let current = open else { return .zeroTick }
        close()
        return current.padding
    }

    /// The padding rest at `index` joins the tuplet it pads, the one stopped last.
    mutating func extendLastTuplet(to index: Int) {
        guard !tuplets.isEmpty else { return }
        tuplets[tuplets.count - 1].last = .index(index)
    }

    private mutating func close() {
        guard let current = open else { return }
        open = nil
        tuplets.append(Tuplet(
            normalNotes: current.normalNotes, actualNotes: current.actualNotes,
            startIndex: current.first, endIndex: current.last, appearance: current.appearance,
        ))
    }

    /// How long a rest completes a tuplet whose members last `duration`: `duration` taken as a fraction in (1/2, 1] of
    /// a power-of-two length, and what that fraction leaves of it — zero when the members already make a whole value.
    /// C++: `MusicXmlTupletState::missingTupletDuration` and `determineTupletFractionAndFullDuration`.
    static func padding(after duration: Fraction) -> Fraction {
        guard duration.numerator > 0 else { return .zeroTick }
        let half = Fraction(numerator: 1, denominator: 2)
        var fraction = duration
        var full = Fraction(numerator: 1, denominator: 1)
        while fraction.denominator % 2 == 0 {
            fraction = MusicXMLTupletNote.scaled(fraction, by: 2, over: 1)
            full = MusicXMLTupletNote.scaled(full, by: 1, over: 2)
        }
        while fraction.numerator % 2 == 0 {
            fraction = MusicXMLTupletNote.scaled(fraction, by: 1, over: 2)
            full = MusicXMLTupletNote.scaled(full, by: 2, over: 1)
        }
        while !half.precedes(fraction) {
            fraction = MusicXMLTupletNote.scaled(fraction, by: 2, over: 1)
            full = MusicXMLTupletNote.scaled(full, by: 1, over: 2)
        }
        // A whole number of `full`s leaves nothing to complete.
        if fraction.denominator == 1 { return .zeroTick }
        let missing = Fraction(numerator: fraction.denominator - fraction.numerator, denominator: fraction.denominator)
        return missing.numerator > 0 ? MusicXMLTupletNote.scaled(full, by: missing.numerator, over: missing.denominator)
            : .zeroTick
    }
}
