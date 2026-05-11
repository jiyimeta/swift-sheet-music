import Foundation

/// Expands MuseScore's header / footer macros (`$P`, `$:tag:`, etc.)
/// into plain text. Mirrors `replaceTextMacros` in
/// `engraving/rendering/score/headerfooterlayout.cpp:246-407`.
///
/// We implement the macros that have a defined meaning in our
/// exporter context. Macros that need data we don't have
/// (filesystem, MuseScore version, build metadata) expand to the
/// empty string. Adding them later is a localised change in
/// `expandToken`.
enum PageChromeMacroExpander {
    /// Inputs needed to expand a single header / footer string.
    struct Context {
        /// 0-based page index. Page 1 is `0`.
        let pageIndex: Int
        /// Total number of pages in the document.
        let pageCount: Int
        /// `Score.metaTags`, looked up by `$:tag:` and the
        /// title / copyright shorthands.
        let metaTags: [String: String]
    }

    /// Expand `template` to its rendered string for the given page.
    /// Tokens that don't match any known macro fall through as
    /// literal `$<char>` (matching MuseScore's `default:` branch).
    static func expand(
        _ template: String, context: Context,
    ) -> String {
        var output = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c != "$" || i + 1 >= chars.count {
                output.append(c)
                i += 1
                continue
            }
            let next = chars[i + 1]
            if next == ":" {
                // `$:tag:` — greedy lookup until the next ':'.
                var j = i + 2
                var tag = ""
                while j < chars.count && chars[j] != ":" {
                    tag.append(chars[j])
                    j += 1
                }
                if j < chars.count {
                    output += context.metaTags[tag] ?? ""
                    i = j + 1
                } else {
                    // Unterminated — emit the literal '$:' and
                    // continue parsing from after '$' so we don't
                    // eat the rest of the string.
                    output.append("$")
                    i += 1
                }
                continue
            }
            output += expandToken(next, context: context)
                ?? "$\(next)"
            i += 2
        }
        return output
    }

    private static func expandToken(
        _ token: Character, context: Context,
    ) -> String? {
        let pageNumber = context.pageIndex + 1
        let isFirstPage = context.pageIndex == 0
        let multiPage = context.pageCount > 1
        switch token {
        case "P":
            return String(pageNumber)
        case "p":
            // "Not on first page" — empty when pageIndex == 0.
            return isFirstPage ? "" : String(pageNumber)
        case "N":
            // "Only when there are multiple pages."
            return multiPage ? String(pageNumber) : ""
        case "n":
            return String(context.pageCount)
        case "T":
            // Convenience alias for `$:workTitle:`. MuseScore
            // doesn't define `$T` itself; documented divergence.
            return context.metaTags["workTitle"] ?? ""
        case "C":
            // Copyright, first page only.
            return isFirstPage
                ? (context.metaTags["copyright"] ?? "")
                : ""
        case "c":
            return context.metaTags["copyright"] ?? ""
        case "$":
            return "$"
        case "i", "I", "f", "F", "d", "D", "m", "M", "v", "r":
            // Deferred — see spec "Deferred" macros table.
            return ""
        default:
            return nil
        }
    }
}
