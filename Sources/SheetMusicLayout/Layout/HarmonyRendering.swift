#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Pure helpers that turn a `Harmony.name` into a `[HarmonyRun]`
/// list and report the resulting typeset width. Used at layout
/// time so wrap / spacing decisions can consult the width before
/// any rendering happens.
public enum HarmonyRendering {
    /// Build the run list for `harmony` at the given staff metrics.
    /// Substitution rules (left-to-right scan):
    ///   1. After an alphanumeric character, `b` / `bb` / `#` / `##`
    ///      become flat / double-flat / sharp / double-sharp glyphs.
    ///   2. For `.roman` / `.nashville`, a leading `b` / `#` (index 0)
    ///      is also recognized as an accidental.
    ///   3. Everything else (digits, slashes, parens, letters) stays
    ///      in a text run; consecutive text characters coalesce.
    public static func runs(
        for harmony: Harmony,
        metrics: StaffMetrics,
    ) -> [HarmonyRun] {
        // Bravura registration (Apple) and CoreText serialization are
        // handled by the `FontMetrics.provider` implementation: the
        // Apple provider's `init` triggers `BravuraFont.register` and
        // serializes CT calls internally. The Stub provider on
        // non-Apple hosts needs neither.
        let displayName = displayedName(for: harmony)
        let kindedSlices = parseSlices(
            name: displayName, harmonyType: harmony.harmonyType,
        )
        let textSize = textPointSize(
            for: harmony, metrics: metrics,
        )
        let glyphSize = glyphPointSize(
            for: harmony, metrics: metrics,
        )
        let textFont = LayoutFont(
            face: textFace(for: harmony),
            pointSize: textSize,
        )
        let glyphFont = LayoutFont(
            face: SMuFLFamily.bravura,
            pointSize: glyphSize,
        )
        // Both renderers (`HarmonyRenderer`/SwiftUI and
        // `ScoreLayerBuilder`/CALayer) place a run by aligning the
        // run's INK left edge with `run.x` — see the
        // `bbox.minX`-based anchor math in
        // `ScoreLayerBuilder+Helpers.textLayer`. So `run.x` is
        // already an ink-aligned position; we just set it to
        // `cursor`. For the advance we use `inkWidth + small_gap`
        // (NOT typographic advance) — the font's natural side
        // bearings would otherwise show up as conspicuous
        // whitespace around every accidental glyph (Bravura's b/#
        // are sized for staff clearance, not chord-symbol use).
        // For multi-character text runs the inkWidth still
        // captures inter-character spacing because CTLine measures
        // the rendered pixel extent of the whole string.
        let textGap = textSize * 0.10
        let accidentalGap = glyphSize * 0.10
        var runs: [HarmonyRun] = []
        var cursor: Double = 0
        for slice in kindedSlices {
            let run: HarmonyRun
            switch slice {
            case let .text(s):
                let bounds = FontMetrics.provider.inkBounds(
                    text: s, font: textFont,
                )
                let width = Double(bounds.width)
                run = HarmonyRun(
                    kind: .text, content: s,
                    advance: width + Double(textGap),
                    x: cursor,
                )
            case let .accidental(a):
                let bounds = FontMetrics.provider.inkBounds(
                    text: String(a.codepoint), font: glyphFont,
                )
                let width = Double(bounds.width)
                run = HarmonyRun(
                    kind: .accidental(a), content: "",
                    advance: width + Double(accidentalGap),
                    x: cursor,
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
        name: String, harmonyType: HarmonyType,
    ) -> [Slice] {
        var out: [Slice] = []
        let chars = Array(name)
        var i = 0
        let allowsLeadingAccidental: Bool
        switch harmonyType {
        case .roman, .nashville: allowsLeadingAccidental = true
        case .standard: allowsLeadingAccidental = false
        }
        let leadingIndex = chars.first == "(" ? 1 : 0
        while i < chars.count {
            let c = chars[i]
            // Decide whether the current cursor position can start
            // an accidental. After-letter rule: previous emitted
            // character must be alphanumeric; leading rule: i == 0
            // AND the harmony type opted in.
            let canBeAccidental: Bool = {
                // A wrapping `(` from `leftParen` must stay
                // transparent here, or `(bVII)` would lose its
                // accidental: the `b` sits at index 1 behind a
                // non-alphanumeric character.
                if i == leadingIndex { return allowsLeadingAccidental }
                guard i > 0 else { return false }
                let prev = chars[i - 1]
                return prev.isLetter || prev.isNumber
            }()
            if canBeAccidental,
               let (acc, consumed) = matchAccidental(
                   chars: chars, at: i,
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
        chars: [Character], at i: Int,
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
        for harmony: Harmony, metrics: StaffMetrics,
    ) -> CGFloat {
        let defaults = harmony.properties.resolved(
            against: harmony.styleType,
        )
        let referenceSp: CGFloat = 5.0
        if defaults.spatiumDependent {
            return CGFloat(defaults.size) * metrics.sp / referenceSp
        }
        return CGFloat(defaults.size)
    }

    /// Glyph point size for chord-symbol accidentals. MuseScore renders
    /// chord-symbol accidentals at the chord text size — NOT at the
    /// staff `glyphFontSize` (which is sized for noteheads, 1 em = 4 sp
    /// ≈ 28 pt at default staff). Matching the text size keeps the
    /// `b` / `#` glyphs visually balanced with the surrounding letters
    /// and prevents the staff-sized SMuFL accidentals from dominating
    /// the symbol. Exposed publicly so renderers configure their
    /// Bravura `Font.custom` / `CTFont` instances at the same size the
    /// width measurement used.
    public static func glyphPointSize(
        for harmony: Harmony,
        metrics: StaffMetrics,
    ) -> CGFloat {
        textPointSize(for: harmony, metrics: metrics)
    }

    /// Reconstruct the displayed chord name. MuseScore stores
    /// `<name>` as either:
    ///   - the *complete* chord text (when no `<root>` is present), OR
    ///   - just the *quality suffix* (when `<root>` TPC is set —
    ///     e.g. `<root>12</root><name>m7</name>` displays as `E♭m7`).
    /// We detect the second case by `rootTpc != nil` and prepend the
    /// root letter + accidental; if `bassTpc` is also present, append
    /// `/` + bass letter + accidental. The `b` / `#` characters
    /// produced here flow back through `parseSlices`'s normal
    /// substitution path and end up as Bravura glyphs in the runs.
    /// `<rootCase>` / `<baseCase>` re-case the note LETTER only, and
    /// `<leftParen/>` / `<rightParen/>` wrap the finished symbol —
    /// MuseScore draws both (`harmony.cpp:202,261`).
    static func displayedName(for harmony: Harmony) -> String {
        var s: String
        if let rootTpc = harmony.rootTpc {
            s = cased(tpcToText(rootTpc), as: harmony.rootCase)
            s += harmony.name
            if let bassTpc = harmony.bassTpc {
                s += "/"
                s += cased(tpcToText(bassTpc), as: harmony.bassCase)
            }
        } else {
            s = harmony.name
        }
        if harmony.leftParen { s = "(" + s }
        if harmony.rightParen { s += ")" }
        return s
    }

    /// Apply a `NoteCase` to a `letter + ASCII accidental` spelling.
    /// Only the leading letter is re-cased: the trailing `b` / `#`
    /// characters are accidental markers that `parseSlices` turns into
    /// glyphs, so lowercasing them would spell `Bb` as a B double-flat.
    /// `.capitalize` / `.auto` are no-ops because `tpcToText` already
    /// emits the capitalized form — mirrors `tpc2name`'s switch
    /// (`pitchspelling.cpp:372-381`).
    private static func cased(
        _ spelling: String, as noteCase: NoteCase,
    ) -> String {
        guard let letter = spelling.first else { return spelling }
        let accidentals = spelling.dropFirst()
        switch noteCase {
        case .lower: return letter.lowercased() + accidentals
        case .upper: return letter.uppercased() + accidentals
        case .auto, .capitalize: return spelling
        }
    }

    /// MuseScore TPC → letter + ASCII accidental (`b` / `#`).
    ///
    /// The line of fifths is anchored at the NATURALS, which
    /// `Tpc` (`engraving/dom/pitchspelling.h:40-51`) places at
    /// `F = 13, C = 14, G = 15, D = 16, A = 17, E = 18, B = 19` — the
    /// enum starts at `TPC_F_BBB = -8`, three alteration rows below
    /// the naturals. So
    ///     letter = (tpc + 1) mod 7 → 0=F, 1=C, 2=G, 3=D, 4=A, 5=E, 6=B
    ///     row    = floor((tpc - 13) / 7) → -2 / -1 / 0 / 1 / 2
    ///         (double-flat / flat / natural / sharp / double-sharp)
    /// which is the same origin `SheetMusicCore.PitchSpelling` and
    /// `PitchStaffPosition.tpcLetters` use. Anchoring one step away
    /// (F = 14) spells every root a fifth flatward — an imported
    /// F minor 7 rendered as B♭m7.
    ///
    /// `tpc == -1` (legacy TPC_INVALID) is normalized to `nil` at
    /// decode time and never reaches here.
    private static func tpcToText(_ tpc: Int) -> String {
        let letters: [Character] = ["F", "C", "G", "D", "A", "E", "B"]
        let letter = letters[(((tpc + 1) % 7) + 7) % 7]
        // Floor division — Swift's `/` truncates toward zero, which
        // gives the wrong sign for the flatward rows (every TPC below
        // 13, i.e. every flat spelling).
        let row = Int((Double(tpc - 13) / 7.0).rounded(.down))
        switch row {
        case -2: return "\(letter)bb"
        case -1: return "\(letter)b"
        case 0: return String(letter)
        case 1: return "\(letter)#"
        case 2: return "\(letter)##"
        default: return String(letter)
        }
    }

    private static func textFace(for harmony: Harmony) -> String {
        harmony.properties.face
            ?? harmony.styleType.museScoreDefault.face
    }
}
