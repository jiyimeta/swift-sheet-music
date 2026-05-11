/// Maps a MuseScore `<Dynamic><subtype>` value to the sequence of
/// SMuFL glyphs that should be drawn from the music font (Bravura).
///
/// MuseScore's `dynamic.cpp` DYN_LIST stores each standard dynamic as
/// an XML template containing one or more `<sym>dynamic*</sym>`
/// references; at draw time `TextBase::createBlocks` substitutes each
/// `<sym>` for the matching code point and switches the fragment's
/// font to the music font (`Sid::musicalSymbolFont = "Leland"` in
/// MuseScore 4, "Bravura" here). The glyphs themselves are bold,
/// thick serif letters baked into the music font — that's why
/// dynamics look noticeably heavier than Edwin italic text.
///
/// Returning `nil` means the subtype isn't a standard symbol
/// dynamic ("cresc.", "espressivo", custom strings, …) and the
/// caller should fall back to plain Edwin italic text.
enum DynamicSymbolMap {
    static func glyphs(for subtype: String) -> [Character]? {
        let trimmed = subtype.trimmingCharacters(
            in: .whitespacesAndNewlines,
        )
        guard !trimmed.isEmpty else { return nil }
        // Only attempt the mapping when every character is one of
        // the seven SMuFL atomic letters; this excludes
        // free-form text dynamics like "cresc." or
        // "molto espressivo".
        var out: [Character] = []
        for ch in trimmed.lowercased() {
            switch ch {
            case "p": out.append(SMuFLGlyph.dynamicPiano)
            case "m": out.append(SMuFLGlyph.dynamicMezzo)
            case "f": out.append(SMuFLGlyph.dynamicForte)
            case "r": out.append(SMuFLGlyph.dynamicRinforzando)
            case "s": out.append(SMuFLGlyph.dynamicSforzando)
            case "z": out.append(SMuFLGlyph.dynamicZ)
            case "n": out.append(SMuFLGlyph.dynamicNiente)
            default:
                return nil
            }
        }
        return out
    }
}
