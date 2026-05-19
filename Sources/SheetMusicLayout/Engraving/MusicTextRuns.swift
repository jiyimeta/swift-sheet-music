import Foundation

/// Splits a mixed-font text string (e.g. a tempo indication or a
/// metronome marking) into Bravura-glyph runs and Edwin-text runs.
///
/// MuseScore stores tempo text like `<sym>metNoteQuarterUp</sym> = 128`
/// where the music symbols resolve to SMuFL Private Use Area codepoints
/// (U+E000–U+F8FF). The Apple SwiftUI renderer and the Android wire
/// format both need to switch fonts at run boundaries; this helper
/// produces that segmentation from a single source of truth.
public enum MusicTextRuns {
    public enum Kind: Sendable, Equatable {
        /// Run consists entirely of SMuFL PUA codepoints — render with
        /// the music font (Bravura) at the SMuFL glyph size.
        case musicSymbol
        /// Run consists of regular text — render with the text font
        /// (Edwin) at the role's text size.
        case text
    }

    public struct Run: Sendable, Equatable {
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Walk `text` and group consecutive characters by whether they
    /// fall inside the SMuFL Private Use Area (U+E000–U+F8FF).
    public static func runs(in text: String) -> [Run] {
        guard !text.isEmpty else { return [] }
        var out: [Run] = []
        var current = ""
        var currentKind: Kind = .text
        var haveSeen = false
        for scalar in text.unicodeScalars {
            let kind: Kind = isMusicSymbol(scalar) ? .musicSymbol : .text
            if !haveSeen {
                currentKind = kind
                current.unicodeScalars.append(scalar)
                haveSeen = true
            } else if currentKind == kind {
                current.unicodeScalars.append(scalar)
            } else {
                out.append(Run(kind: currentKind, text: current))
                current = String(scalar)
                currentKind = kind
            }
        }
        if haveSeen, !current.isEmpty {
            out.append(Run(kind: currentKind, text: current))
        }
        return out
    }

    /// True when `scalar` falls in Bravura's SMuFL Private Use Area
    /// (U+E000–U+F8FF), the range every SMuFL music symbol lives in.
    public static func isMusicSymbol(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0xE000 && scalar.value <= 0xF8FF
    }
}
