import CoreGraphics
import CoreText
import Foundation
import SheetMusicCore

/// Pure helpers that turn a `Harmony.name` into a `[HarmonyRun]`
/// list and report the resulting typeset width. Used at layout
/// time so wrap / spacing decisions can consult the width before
/// any rendering happens.
@available(macOS 15.0, iOS 16.0, *)
public enum HarmonyRendering {
    /// Build the run list for `harmony` at the given staff metrics.
    /// Substitution rules (left-to-right scan):
    ///   1. After an alphanumeric character, `b` / `bb` / `#` / `##`
    ///      become flat / double-flat / sharp / double-sharp glyphs.
    ///   2. For `.roman` / `.nashville`, a leading `b` / `#` (index 0)
    ///      is also recognised as an accidental.
    ///   3. Everything else (digits, slashes, parens, letters) stays
    ///      in a text run; consecutive text characters coalesce.
    public static func runs(
        for harmony: Harmony,
        metrics: StaffMetrics
    ) -> [HarmonyRun] {
        let kindedSlices = parseSlices(
            name: harmony.name, harmonyType: harmony.harmonyType
        )
        let textPointSize = textPointSize(
            for: harmony, metrics: metrics
        )
        let glyphPointSize = glyphPointSize(metrics: metrics)
        let textFont = makeFont(
            face: textFace(for: harmony),
            pointSize: textPointSize
        )
        let glyphFont = makeFont(
            face: "Bravura",
            pointSize: glyphPointSize
        )
        var runs: [HarmonyRun] = []
        var cursor: Double = 0
        for slice in kindedSlices {
            let run: HarmonyRun
            switch slice {
            case let .text(s):
                let advance = measure(s, font: textFont)
                run = HarmonyRun(
                    kind: .text, content: s,
                    advance: advance, x: cursor
                )
            case let .accidental(a):
                let advance = measure(
                    String(a.codepoint), font: glyphFont
                )
                run = HarmonyRun(
                    kind: .accidental(a), content: "",
                    advance: advance, x: cursor
                )
            }
            runs.append(run)
            cursor += run.advance
        }
        return runs
    }

    /// Sum of the `advance` values. Equivalent to the rightmost
    /// run's `x + advance`. Provided as a separate helper because
    /// the public `LayoutHarmony.width` field is the contract — a
    /// regression here would silently desynchronise the spacing
    /// engine and the renderer.
    public static func width(of runs: [HarmonyRun]) -> Double {
        runs.reduce(0.0) { $0 + $1.advance }
    }

    // MARK: - Internals

    private enum Slice {
        case text(String)
        case accidental(HarmonyAccidental)
    }

    /// Walks `name` once, emitting Slice values. Consecutive text
    /// characters are merged at append time.
    private static func parseSlices(
        name: String, harmonyType: HarmonyType
    ) -> [Slice] {
        var out: [Slice] = []
        let chars = Array(name)
        var i = 0
        let allowsLeadingAccidental: Bool
        switch harmonyType {
        case .roman, .nashville: allowsLeadingAccidental = true
        case .standard: allowsLeadingAccidental = false
        }
        while i < chars.count {
            let c = chars[i]
            // Decide whether the current cursor position can start
            // an accidental. After-letter rule: previous emitted
            // character must be alphanumeric; leading rule: i == 0
            // AND the harmony type opted in.
            let canBeAccidental: Bool = {
                if i == 0 { return allowsLeadingAccidental }
                let prev = chars[i - 1]
                return prev.isLetter || prev.isNumber
            }()
            if canBeAccidental,
               let (acc, consumed) = matchAccidental(
                   chars: chars, at: i
               )
            {
                out.append(.accidental(acc))
                i += consumed
                continue
            }
            // Plain text — coalesce into the previous text slice.
            if case let .text(s) = out.last {
                out[out.count - 1] = .text(s + String(c))
            } else {
                out.append(.text(String(c)))
            }
            i += 1
        }
        return out
    }

    /// Try to match an accidental starting at `chars[i]`. Returns
    /// `(accidental, characters consumed)` or `nil` on no match.
    /// Greedy: prefers the 2-char form (`bb`, `##`) over the 1-char.
    private static func matchAccidental(
        chars: [Character], at i: Int
    ) -> (HarmonyAccidental, Int)? {
        let c = chars[i]
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        switch c {
        case "b":
            if next == "b" { return (.doubleFlat, 2) }
            return (.flat, 1)
        case "#":
            if next == "#" { return (.doubleSharp, 2) }
            return (.sharp, 1)
        default:
            return nil
        }
    }

    private static func textPointSize(
        for harmony: Harmony, metrics: StaffMetrics
    ) -> CGFloat {
        let defaults = harmony.properties.resolved(
            against: harmony.styleType
        )
        let referenceSp: CGFloat = 5.0
        if defaults.spatiumDependent {
            return CGFloat(defaults.size) * metrics.sp / referenceSp
        }
        return CGFloat(defaults.size)
    }

    /// SMuFL convention: 1 em = 4 sp. Match `StaffMetrics.glyphFontSize`.
    private static func glyphPointSize(
        metrics: StaffMetrics
    ) -> CGFloat {
        metrics.glyphFontSize
    }

    private static func textFace(for harmony: Harmony) -> String {
        harmony.properties.face
            ?? harmony.styleType.museScoreDefault.face
    }

    private static func makeFont(
        face: String, pointSize: CGFloat
    ) -> CTFont {
        CTFontCreateWithName(face as CFString, pointSize, nil)
    }

    /// CoreText typesetting advance for a string in `font`. Falls
    /// back to the platform system font if `face` is unregistered
    /// (CTFont's cascade list handles this automatically), so the
    /// reported width stays sensible even when Edwin / Campania /
    /// Bravura are missing at test-time.
    private static func measure(
        _ string: String, font: CTFont
    ) -> Double {
        let attr = NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]
        )
        let line = CTLineCreateWithAttributedString(
            attr as CFAttributedString
        )
        let typographicBounds = CTLineGetTypographicBounds(
            line, nil, nil, nil
        )
        return Double(typographicBounds)
    }
}
