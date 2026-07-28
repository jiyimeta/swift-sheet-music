import Foundation

/// A glyph NAME → the text it stands for, per the Adobe Glyph List.
///
/// This is the TEXT counterpart of `GlyphNameTable`, which maps the same key
/// space to MUSIC semantics. A simple font's `/Encoding /Differences` names
/// every code it re-encodes, and for an ordinary text font those names are
/// AGL names — so a code `Differences` covers decodes to a character here
/// even when the font ships no `/ToUnicode` CMap at all.
///
/// Names outside the list decline rather than guess: subsetting replaces real
/// names with synthetic ones (`g23`, `gid12`, `cid5`), and a music font's
/// names (`noteheadBlack`) belong to `GlyphNameTable`, not here.
///
/// The name → codepoint data in `packedTable` is derived from Adobe's
/// `glyphlist.txt` (Adobe Glyph List 2.0, Copyright 2002, 2010, 2015 Adobe
/// Systems Incorporated, licensed under the Apache License 2.0), narrowed to
/// the single-scalar names a 1-byte font can reach. See `NOTICE`.
enum AdobeGlyphList {
    /// Decode `raw` — a `/Differences` glyph name — to the text it stands
    /// for, or nil when no rule applies.
    ///
    /// Implements the three rules of Adobe's "Unicode and Glyph Names", in
    /// the order that document gives them: strip a `.variant` suffix, split a
    /// `_`-joined ligature name into components, and resolve each component
    /// through the list or through the algorithmic `uniXXXX` / `uXXXX…` form.
    /// A ligature whose components do not ALL resolve declines outright — a
    /// partial answer would silently drop letters from a word.
    static func text(forGlyphName raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let base = raw.prefix { $0 != "." }
        guard !base.isEmpty else { return nil }
        var out = ""
        for component in base.split(separator: "_", omittingEmptySubsequences: false) {
            guard let text = text(forComponent: component) else { return nil }
            out += text
        }
        return out.isEmpty ? nil : out
    }

    private static func text(forComponent name: Substring) -> String? {
        if let cp = table[String(name)], let scalar = Unicode.Scalar(cp) {
            return String(scalar)
        }
        return algorithmicText(name)
    }

    /// `uniXXXX` (one or more 4-digit groups) and `uXXXX`…`uXXXXXX` — the two
    /// forms that carry the codepoint in the name itself. `Unicode.Scalar`
    /// declines surrogates and out-of-range values, so a malformed name
    /// resolves to nothing rather than to a replacement character.
    private static func algorithmicText(_ name: Substring) -> String? {
        if name.hasPrefix("uni") {
            let hex = name.dropFirst(3)
            guard hex.count >= 4, hex.count.isMultiple(of: 4),
                  hex.allSatisfy(\.isHexDigit) else { return nil }
            var out = ""
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 4)
                guard let cp = UInt32(hex[index ..< next], radix: 16),
                      let scalar = Unicode.Scalar(cp) else { return nil }
                out.unicodeScalars.append(scalar)
                index = next
            }
            return out
        }
        guard name.hasPrefix("u") else { return nil }
        let hex = name.dropFirst()
        guard hex.count >= 4, hex.count <= 6, hex.allSatisfy(\.isHexDigit),
              let cp = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(cp)
        else { return nil }
        return String(scalar)
    }

    /// Name → codepoint, parsed once from `packedTable`.
    private static let table: [String: UInt32] = {
        var out: [String: UInt32] = [:]
        var pendingName: Substring?
        for token in packedTable.split(whereSeparator: \.isWhitespace) {
            guard let name = pendingName else {
                pendingName = token
                continue
            }
            pendingName = nil
            guard let cp = UInt32(token, radix: 16) else { continue }
            out[String(name)] = cp
        }
        return out
    }()
}
