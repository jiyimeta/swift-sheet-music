#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Turns the characters an OCR pass read on a raster page into the same per-character `TextGlyph`s the content-stream
/// walker produces for a vector page, so the lyric, title and tempo passes run on them unchanged.
///
/// Everything here is portable Swift; the recognizer is the only platform-specific step.
enum OCRTextGlyphs {
    /// The `fontName` every OCR glyph carries.
    static let fontName = "OCR"

    /// A gap between two characters' boxes wider than this many line heights starts a new token, even when the line
    /// string has no whitespace there (the recognizer does not always report one).
    static let tokenGapLineHeights = 0.5

    /// These are starting values; Task 9 tunes them on the harness.
    private static let dynamics: Set = [
        "p", "pp", "ppp", "pppp", "mp", "mf", "f", "ff", "fff", "ffff",
        "sf", "sfz", "sffz", "fz", "fp", "rf", "rfz", "sfp",
    ]
    private static let directionWords: Set = [
        "cresc", "decresc", "dim", "rit", "ritard", "rall", "accel", "ped", "simile",
    ]

    /// One glyph per non-whitespace character of every line.
    ///
    /// The origin is the character's left edge on the line's bottom, so every character of a line shares one baseline
    /// and verse clustering sees one row. `fontSize` and `renderedSize` are one value per line, so the title pass's
    /// same-size test groups a line. `bbox` is left `.zero`, like every walker glyph.
    static func textGlyphs(from lines: [RasterTextLine], transform: PageTransform, pageIndex: Int) -> [TextGlyph] {
        var glyphs: [TextGlyph] = []
        for line in lines {
            let size = CGFloat(line.rect.height * 72 / transform.dpi)
            let tokens = tokenRanges(of: line)
            let eligibility = tokenEligibility(of: line, tokens: tokens)
            for (token, eligible) in zip(tokens, eligibility) {
                for index in token {
                    let character = line.characters[index]
                    glyphs.append(TextGlyph(
                        text: character.text,
                        fontName: fontName,
                        fontSize: size,
                        renderedSize: size,
                        origin: transform.point(x: character.rect.x, y: line.rect.maxY),
                        bbox: .zero,
                        pageIndex: pageIndex,
                        ocr: OCRTextInfo(
                            inkCenterX: transform.point(x: character.rect.midX, y: line.rect.maxY).x,
                            lyricEligible: eligible,
                        ),
                    ))
                }
            }
        }
        return glyphs
    }

    /// Whether a token (a run of characters between whitespace in the line string, or between box gaps wider than
    /// `tokenGapLineHeights` × the line height) may become a lyric.
    ///
    /// False when the token has no letter (digits, punctuation, symbols), when it is a dynamic or a direction word
    /// (compared lowercased, with leading and trailing non-letters removed), or when it is the two-word `a tempo`.
    static func isLyricEligible(_ token: String) -> Bool {
        guard token.contains(where: \.isLetter) else { return false }
        let normalized = strippedOfOuterNonLetters(token)
        if normalized == "a tempo" { return false }
        return !dynamics.contains(normalized) && !directionWords.contains(normalized)
    }

    /// `token` lowercased with the non-letters at both ends removed, so `Ped.*`, `(p)` and `mf,` match their words.
    /// Interior characters (`shin-ing`, apostrophes) are kept.
    private static func strippedOfOuterNonLetters(_ token: String) -> String {
        let lowered = Substring(token.lowercased())
        guard let first = lowered.firstIndex(where: \.isLetter),
              let last = lowered.lastIndex(where: \.isLetter)
        else { return "" }
        return String(lowered[first ... last])
    }

    // MARK: - Tokens

    /// The index ranges into `line.characters` of each token, in reading order.
    ///
    /// A token ends at a box gap wider than `tokenGapLineHeights` line heights, or where the line string has
    /// whitespace. The string is aligned to the boxes by its non-whitespace characters; when their counts differ the
    /// alignment is unknown, so only the gaps split the line.
    private static func tokenRanges(of line: RasterTextLine) -> [Range<Int>] {
        let characters = line.characters
        guard !characters.isEmpty else { return [] }
        let whitespaceBefore = whitespaceBeforeEachCharacter(of: line)
        let maxGap = tokenGapLineHeights * line.rect.height

        var ranges: [Range<Int>] = []
        var start = 0
        for index in 1 ..< characters.count {
            let gap = characters[index].rect.x - characters[index - 1].rect.maxX
            if gap > maxGap || whitespaceBefore?[index] == true {
                ranges.append(start ..< index)
                start = index
            }
        }
        ranges.append(start ..< characters.count)
        return ranges
    }

    /// For each box, whether whitespace precedes it in `line.text`; `nil` when the string's non-whitespace characters
    /// do not match the boxes one to one.
    private static func whitespaceBeforeEachCharacter(of line: RasterTextLine) -> [Bool]? {
        var flags: [Bool] = []
        var pending = false
        for character in line.text {
            if character.isWhitespace {
                pending = true
            } else {
                flags.append(pending)
                pending = false
            }
        }
        return flags.count == line.characters.count ? flags : nil
    }

    /// The eligibility of each token of `line`; the two tokens of `a tempo` are both ineligible.
    private static func tokenEligibility(of line: RasterTextLine, tokens: [Range<Int>]) -> [Bool] {
        let strings = tokens.map { range in line.characters[range].map(\.text).joined() }
        var eligibility = strings.map(isLyricEligible)
        for index in strings.indices.dropLast()
            where strippedOfOuterNonLetters(strings[index]) == "a"
            && strippedOfOuterNonLetters(strings[index + 1]) == "tempo"
        {
            eligibility[index] = false
            eligibility[index + 1] = false
        }
        return eligibility
    }
}
