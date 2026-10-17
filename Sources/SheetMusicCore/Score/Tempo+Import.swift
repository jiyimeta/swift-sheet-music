import SheetMusicFoundation

extension Tempo {
    /// The beat a marking's printed number counts in. An imported tempo plays quarter-normalized (quarter beats per
    /// second, whatever file format it came from) but the marking is drawn in whatever note the author chose. The
    /// drawn value equals `beatsPerSecond * 60 / (beatLength / quarter)`, so the beat length in quarters is
    /// `beatsPerSecond * 60 / printedValue`. The printed number is read out of the text (after the last `=`, else the
    /// first number) and that ratio is snapped to the nearest standard note (0–2 dots). Falls back to a plain quarter
    /// when the text has no number, either value is not positive, or the ratio matches nothing — the same assumption
    /// the engine makes for an unannotated tempo. This mirrors MuseScore's TempoText math rather than parsing the
    /// (version-dependent) note glyph from the text.
    package static func beatUnit(
        inPrintedText text: String, beatsPerSecond: Double,
    ) -> (note: NoteDuration, dots: Int) {
        let fallback: (NoteDuration, Int) = (.quarter, 0)
        guard let printed = printedTempoValue(in: text),
              printed > 0,
              beatsPerSecond > 0
        else { return fallback }
        let quartersPerBeat = beatsPerSecond * 60 / printed
        return matchBeat(quartersPerBeat: quartersPerBeat) ?? fallback
    }

    /// Takes an imported text and its markup as the marking's words — unless the markup is exactly the marking this
    /// library would print, which stays derived (`text` and `preservedTextMarkup` untouched), so a marking saved by
    /// this library or MuseScore's palette edits like one made here.
    package mutating func adoptText(_ markup: PreservedTextMarkup?, plainText: String) {
        if let markup, isSynthesizedMarking(markup) { return }
        text = plainText
        preservedTextMarkup = markup
    }

    /// The metronome number printed in a tempo marking — the 80 in "♩. = 80". Reads the first number after the last
    /// `=` (so a leading "Allegro 1:" or the note glyph don't get picked up); if there's no `=`, the first number in
    /// the whole string.
    private static func printedTempoValue(in text: String) -> Double? {
        // `lastIndex(of:)` rather than `range(of:options: .backwards)`:
        // the latter is umbrella-only and this target builds for wasm.
        let scope: String = if let equals = text.lastIndex(of: "=") {
            String(text[text.index(after: equals)...])
        } else {
            text
        }
        var digits = ""
        for ch in scope {
            if ch.isNumber || (ch == "." && !digits.isEmpty) {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }

    /// Snap a beat length (in quarter notes) to the nearest standard note value carrying 0–2 augmentation dots.
    /// Returns nil when nothing lands within tolerance.
    private static func matchBeat(
        quartersPerBeat target: Double,
    ) -> (note: NoteDuration, dots: Int)? {
        let bases: [NoteDuration] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
        var best: (note: NoteDuration, dots: Int, error: Double)?
        for base in bases {
            for dots in 0 ... 2 {
                let beat = base.dotted(dots).asFraction
                let lengthInQuarters = (Double(beat.numerator) / Double(beat.denominator)) / 0.25
                let error = abs(lengthInQuarters - target)
                guard error < 0.01 else { continue }
                if error < (best?.error ?? .greatestFiniteMagnitude) {
                    best = (base, dots, error)
                }
            }
        }
        return best.map { ($0.note, $0.dots) }
    }
}
