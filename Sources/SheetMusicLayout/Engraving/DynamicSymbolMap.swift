import SheetMusicFoundation

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
///
/// Lives in `SheetMusicLayout` (not the Apple-only `SheetMusicUI`) so
/// the Apple renderer and the Android `LayoutBridge` share one mapping
/// instead of diverging — see the iOS/Android parity rule.
public enum DynamicSymbolMap {
    /// SMuFL code points for the atomic dynamic letters composing
    /// `subtype`, or `nil` when the string contains any non-dynamic
    /// character (free-form text dynamic).
    public static func codepoints(for subtype: String) -> [UInt32]? {
        let trimmed = subtype.trimmingWhitespaceAndNewlines()
        guard !trimmed.isEmpty else { return nil }
        // Only attempt the mapping when every character is one of the
        // seven SMuFL atomic letters; this excludes free-form text
        // dynamics like "cresc." or "molto espressivo".
        var out: [UInt32] = []
        for ch in trimmed.lowercased() {
            switch ch {
            case "p": out.append(SMuFLCodepoint.dynamicPiano)
            case "m": out.append(SMuFLCodepoint.dynamicMezzo)
            case "f": out.append(SMuFLCodepoint.dynamicForte)
            case "r": out.append(SMuFLCodepoint.dynamicRinforzando)
            case "s": out.append(SMuFLCodepoint.dynamicSforzando)
            case "z": out.append(SMuFLCodepoint.dynamicZ)
            case "n": out.append(SMuFLCodepoint.dynamicNiente)
            default:
                return nil
            }
        }
        return out
    }

    /// Convenience for Apple renderers that draw via a `String`
    /// (CoreText). Returns the mapped glyphs as a single string, or
    /// `nil` for free-form text dynamics.
    public static func glyphString(for subtype: String) -> String? {
        guard let cps = codepoints(for: subtype) else { return nil }
        var view = String.UnicodeScalarView()
        for cp in cps {
            if let scalar = UnicodeScalar(cp) { view.append(scalar) }
        }
        return String(view)
    }
}
