import SheetMusicFoundation

/// How MuseScore reads a tempo marking's text: `TempoText::updateTempo` (`engraving/dom/tempotext.cpp:260-318`) over
/// its plain text, in which every `<sym>` stands as its glyph's codepoint and `<sym>space</sym>` as a space.
///
/// Read where the words of a marking decide what an edit does to them (`SetTempo`'s number-edit rule, spec §5.6).
enum TempoTextEquation: Sendable, Equatable {
    /// No "beat = number" and no "beat = beat" anywhere: words alone ("Allegro", "a tempo").
    case words
    /// "beat = beat", a metric modulation. MuseScore resolves it once, when the text is typed, and stores the result.
    case relative
    /// "beat = number". `isWholeText` when, after MuseScore's normalization, nothing but the equation is written.
    case metronome(beatQuarters: Double, number: Double, isWholeText: Bool)

    init(_ text: RichText) {
        self = Self.classify(Self.normalized(text))
    }
}

extension TempoTextEquation {
    /// One row of MuseScore's `tp` table (`tempotext.cpp:113-136`): a metronome note, the dots after it, and the beat's
    /// length in quarters. Kept in the table's order — longer patterns first, quarter notes before every other value.
    struct Pattern {
        let note: Unicode.Scalar
        let dots: Int
        let quarters: Double
    }

    static let dot: Unicode.Scalar = "\u{ECB7}"

    static let patterns: [Pattern] = [
        Pattern(note: "\u{ECA5}", dots: 2, quarters: 1.75),
        Pattern(note: "\u{ECA5}", dots: 1, quarters: 1.5),
        Pattern(note: "\u{ECA5}", dots: 0, quarters: 1),
        Pattern(note: "\u{ECA3}", dots: 2, quarters: 3.5),
        Pattern(note: "\u{ECA3}", dots: 1, quarters: 3),
        Pattern(note: "\u{ECA3}", dots: 0, quarters: 2),
        Pattern(note: "\u{ECA7}", dots: 2, quarters: 0.875),
        Pattern(note: "\u{ECA7}", dots: 1, quarters: 0.75),
        Pattern(note: "\u{ECA7}", dots: 0, quarters: 0.5),
        Pattern(note: "\u{ECA2}", dots: 1, quarters: 6),
        Pattern(note: "\u{ECA2}", dots: 0, quarters: 4),
        Pattern(note: "\u{ECA9}", dots: 1, quarters: 0.375),
        Pattern(note: "\u{ECA9}", dots: 0, quarters: 0.25),
        Pattern(note: "\u{ECAB}", dots: 1, quarters: 0.1875),
        Pattern(note: "\u{ECAB}", dots: 0, quarters: 0.125),
        Pattern(note: "\u{ECA1}", dots: 0, quarters: 8),
        Pattern(note: "\u{ECA0}", dots: 0, quarters: 8),
        Pattern(note: "\u{ECAD}", dots: 0, quarters: 0.0625),
        Pattern(note: "\u{ECAF}", dots: 0, quarters: 0.03125),
        Pattern(note: "\u{ECB1}", dots: 0, quarters: 0.015625),
        Pattern(note: "\u{ECB3}", dots: 0, quarters: 0.0078125),
        Pattern(note: "\u{ECB5}", dots: 0, quarters: 0.00390625),
    ]

    /// The SMuFL metronome-mark range (U+ECA0–U+ECB7) by the names MuseScore writes inside a tempo's `<sym>`s. The
    /// stem-down notes are here so they read as glyphs, not words — MuseScore's table simply never matches them.
    static let metronomeCodepoints: [String: Unicode.Scalar] = [
        "metNoteDoubleWhole": "\u{ECA0}", "metNoteDoubleWholeSquare": "\u{ECA1}", "metNoteWhole": "\u{ECA2}",
        "metNoteHalfUp": "\u{ECA3}", "metNoteHalfDown": "\u{ECA4}", "metNoteQuarterUp": "\u{ECA5}",
        "metNoteQuarterDown": "\u{ECA6}", "metNote8thUp": "\u{ECA7}", "metNote8thDown": "\u{ECA8}",
        "metNote16thUp": "\u{ECA9}", "metNote16thDown": "\u{ECAA}", "metNote32ndUp": "\u{ECAB}",
        "metNote32ndDown": "\u{ECAC}", "metNote64thUp": "\u{ECAD}", "metNote64thDown": "\u{ECAE}",
        "metNote128thUp": "\u{ECAF}", "metNote128thDown": "\u{ECB0}", "metNote256thUp": "\u{ECB1}",
        "metNote256thDown": "\u{ECB2}", "metNote512thUp": "\u{ECB3}", "metNote512thDown": "\u{ECB4}",
        "metNote1024thUp": "\u{ECB5}", "metNote1024thDown": "\u{ECB6}", "metAugmentationDot": "\u{ECB7}",
    ]

    /// MuseScore's replacements, in its order (`tempotext.cpp:266-273`).
    static let replacements: [(String, String)] = [
        (",", "."), ("≒", "="), ("≈", "="), ("~", "="), ("ca.", ""), ("c.", ""), ("approx.", ""),
    ]

    /// The text as `updateTempo` reads it, as Unicode scalars (MuseScore's regexes see codepoints, so a combining mark
    /// never fuses with the glyph or "=" before it): runs flattened in order, a line break as "\n", a metronome `<sym>`
    /// as its codepoint, `space` as " ", any other symbol as nothing (MuseScore inserts nothing for an unknown id),
    /// then MuseScore's replacements.
    static func normalized(_ text: RichText) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        for (index, line) in text.lines.enumerated() {
            if index > 0 { scalars.append("\n") }
            for run in line {
                switch run {
                case let .text(string, _):
                    scalars += string.unicodeScalars
                case let .symbol(name, _):
                    if name == "space" {
                        scalars.append(" ")
                    } else if let codepoint = metronomeCodepoints[name] {
                        scalars.append(codepoint)
                    }
                }
            }
        }
        for (target, replacement) in replacements {
            scalars = replacing(Array(target.unicodeScalars), with: Array(replacement.unicodeScalars), in: scalars)
        }
        return scalars
    }

    /// `updateTempo`'s search: for each pattern in table order, "pattern = number" anywhere, else "pattern = any
    /// pattern" anywhere; the first that matches decides.
    static func classify(_ text: [Unicode.Scalar]) -> TempoTextEquation {
        for pattern in patterns {
            let starts = text.indices.filter { text[$0] == pattern.note }
            for start in starts {
                guard let afterEquals = equalsSign(after: pattern, at: start, in: text),
                      let number = number(at: afterEquals, in: text)
                else { continue }
                let isWhole = text[..<start].allSatisfy(isSpace) && text[number.end...].allSatisfy(isSpace)
                return .metronome(beatQuarters: pattern.quarters, number: number.value, isWholeText: isWhole)
            }
            for start in starts {
                guard let afterEquals = equalsSign(after: pattern, at: start, in: text) else { continue }
                if patterns.contains(where: { beatEnd(of: $0, at: afterEquals, in: text) != nil }) {
                    return .relative
                }
            }
        }
        return .words
    }

    /// Where `pattern`'s beat starting at `start` ends — the note, then exactly `pattern.dots` dots, each after
    /// optional whitespace (`\s*`) — or `nil` when the text there spells another beat.
    static func beatEnd(of pattern: Pattern, at start: Int, in text: [Unicode.Scalar]) -> Int? {
        guard start < text.count, text[start] == pattern.note else { return nil }
        var cursor = start + 1
        for _ in 0 ..< pattern.dots {
            cursor = skipWhitespace(from: cursor, in: text)
            guard cursor < text.count, text[cursor] == dot else { return nil }
            cursor += 1
        }
        if pattern.dots < 2 {
            let next = skipWhitespace(from: cursor, in: text)
            if next < text.count, text[next] == dot { return nil }
        }
        return cursor
    }

    /// After `pattern`'s beat at `start`: optional whitespace, "=", optional whitespace — the index after them.
    static func equalsSign(after pattern: Pattern, at start: Int, in text: [Unicode.Scalar]) -> Int? {
        guard let end = beatEnd(of: pattern, at: start, in: text) else { return nil }
        let sign = skipWhitespace(from: end, in: text)
        guard sign < text.count, text[sign] == "=" else { return nil }
        return skipWhitespace(from: sign + 1, in: text)
    }

    /// `\d+[.]{0,1}\d*` at `start`, then any whitespace: its value and the index after it all. The value is
    /// `Double(digits)`, which is +infinity for an absurdly long run of digits; callers clamp what they do with it.
    static func number(at start: Int, in text: [Unicode.Scalar]) -> (value: Double, end: Int)? {
        var cursor = start
        while cursor < text.count, isDigit(text[cursor]) {
            cursor += 1
        }
        guard cursor > start else { return nil }
        var digits = String(String.UnicodeScalarView(text[start ..< cursor]))
        if cursor < text.count, text[cursor] == "." {
            cursor += 1
            let fraction = cursor
            while cursor < text.count, isDigit(text[cursor]) {
                cursor += 1
            }
            if cursor > fraction { digits += "." + String(String.UnicodeScalarView(text[fraction ..< cursor])) }
        }
        guard let value = Double(digits) else { return nil }
        return (value, skipWhitespace(from: cursor, in: text))
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0" ... "9").contains(scalar)
    }

    /// The ASCII `\s` set: space, tab, line feed, vertical tab, form feed, carriage return.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || ("\t" ... "\r").contains(scalar)
    }

    private static func skipWhitespace(from start: Int, in text: [Unicode.Scalar]) -> Int {
        var cursor = start
        while cursor < text.count, isSpace(text[cursor]) {
            cursor += 1
        }
        return cursor
    }

    private static func matches(_ target: [Unicode.Scalar], at index: Int, in text: [Unicode.Scalar]) -> Bool {
        guard index + target.count <= text.count else { return false }
        for offset in target.indices where text[index + offset] != target[offset] {
            return false
        }
        return true
    }

    private static func replacing(
        _ target: [Unicode.Scalar], with replacement: [Unicode.Scalar], in text: [Unicode.Scalar],
    ) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        var index = 0
        while index < text.count {
            if matches(target, at: index, in: text) {
                result += replacement
                index += target.count
            } else {
                result.append(text[index])
                index += 1
            }
        }
        return result
    }
}
