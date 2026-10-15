import SheetMusicFoundation

// MuseScore regenerates a capo's text on every layout (`Capo::generateText`, `dom/capo.cpp:144-175`); ssm draws the
// file's own text and falls back to the same English literals only when that text is empty.

extension Capo {
    /// `Capo::generateText` in English: "No capo" when inactive or on fret 0, "Capo N" on a whole fret, and for a
    /// partial capo the 1-based strings it applies to. `""` for a partial capo when `stringCount` is unknown — the
    /// strings it applies to cannot be named.
    func generatedText(stringCount: Int?) -> String {
        guard isActive, fretPosition != 0 else { return "No capo" }
        guard !ignoredStrings.isEmpty else { return "Capo \(fretPosition)" }
        guard let stringCount else { return "" }
        let applied = (0 ..< max(stringCount, 0)).filter { !ignoredStrings.contains($0) }
        guard !applied.isEmpty else { return "No capo" }
        let list = applied.map { "\($0 + 1)" }.joined(separator: ", ")
        return "Partial capo:\nFret \(fretPosition) on strings \(list)"
    }

    /// The file's text, else the generated one.
    package func displayedText(stringCount: Int?) -> String {
        text.isEmpty ? generatedText(stringCount: stringCount) : text
    }
}
