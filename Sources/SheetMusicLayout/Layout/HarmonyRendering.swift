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
        // Serialise the entire CT-using path. CoreText's
        // `CTFontCreateWithName` and `CTLineCreateWithAttributedString`
        // hit a global lock for unregistered family names and
        // deadlock under concurrent access (Swift Testing runs test
        // functions in parallel). One mutex around the whole pipeline
        // is simpler and faster than diagnosing CT's lock topology.
        ctLock.lock()
        defer { ctLock.unlock() }
        let displayName = displayedName(for: harmony)
        let kindedSlices = parseSlices(
            name: displayName, harmonyType: harmony.harmonyType
        )
        let textSize = textPointSize(
            for: harmony, metrics: metrics
        )
        let glyphSize = glyphPointSize(
            for: harmony, metrics: metrics
        )
        let textFont = makeFont(
            face: textFace(for: harmony),
            pointSize: textSize
        )
        let glyphFont = makeFont(
            face: "Bravura",
            pointSize: glyphSize
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
        // Tighten the gap on either side of accidental glyphs to a
        // hair (~0.04 em). Bravura's chord-symbol accidentals are
        // visually inset enough that even 0.10 em looks like loose
        // padding next to ASCII letters whose strokes butt right up
        // to the cell edge.
        let accidentalGap = glyphSize * 0.04
        var runs: [HarmonyRun] = []
        var cursor: Double = 0
        for slice in kindedSlices {
            let run: HarmonyRun
            switch slice {
            case let .text(s):
                let bounds = inkBounds(s, font: textFont)
                run = HarmonyRun(
                    kind: .text, content: s,
                    advance: bounds.width + textGap,
                    x: cursor
                )
            case let .accidental(a):
                let bounds = inkBounds(
                    String(a.codepoint), font: glyphFont
                )
                run = HarmonyRun(
                    kind: .accidental(a), content: "",
                    advance: bounds.width + accidentalGap,
                    x: cursor
                )
            }
            runs.append(run)
            cursor += run.advance
        }
        return runs
    }

    /// Single mutex guarding all CoreText calls in this enum.
    private nonisolated(unsafe) static let ctLock = NSLock()

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
        metrics: StaffMetrics
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
    static func displayedName(for harmony: Harmony) -> String {
        guard let rootTpc = harmony.rootTpc else {
            return harmony.name
        }
        var s = tpcToText(rootTpc)
        s += harmony.name
        if let bassTpc = harmony.bassTpc {
            s += "/"
            s += tpcToText(bassTpc)
        }
        return s
    }

    /// MuseScore TPC → letter + ASCII accidental (`b` / `#`).
    /// Convention (`engraving/dom/pitchspelling.cpp`): the cycle of
    /// fifths starts at F♭♭ = 0 and ascends in fifths, so
    ///     row = floor(tpc / 7) - 2 → -2 / -1 / 0 / 1 / 2
    ///         (double-flat / flat / natural / sharp / double-sharp)
    ///     letter = tpc mod 7 → 0=F, 1=C, 2=G, 3=D, 4=A, 5=E, 6=B.
    /// `tpc < 0` (TPC_INVALID) is normalised to `nil` at decode time
    /// and never reaches here.
    private static func tpcToText(_ tpc: Int) -> String {
        let letters: [Character] = ["F", "C", "G", "D", "A", "E", "B"]
        let letter = letters[((tpc % 7) + 7) % 7]
        // Floor division — Swift's `/` truncates toward zero, which
        // gives the wrong sign for negative TPCs. We never see
        // negative TPCs in practice (decoder normalises -1 → nil),
        // but using floor keeps the math correct if someone ever
        // passes a raw value through.
        let row = Int((Double(tpc) / 7.0).rounded(.down)) - 2
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

    /// Per-(face, size) CTFont cache. Caller already holds `ctLock`.
    private nonisolated(unsafe) static var fontCache:
        [String: CTFont] = [:]

    private static func makeFont(
        face: String, pointSize: CGFloat
    ) -> CTFont {
        let key = "\(face)|\(pointSize)"
        if let cached = fontCache[key] { return cached }
        let font = CTFontCreateWithName(face as CFString, pointSize, nil)
        fontCache[key] = font
        return font
    }

    /// CoreText typesetting advance for a string in `font`. Falls
    /// back to the platform system font if `face` is unregistered
    /// (CTFont's cascade list handles this automatically), so the
    /// reported width stays sensible even when Edwin / Campania /
    /// Bravura are missing at test-time.
    /// Visual ink metrics for one glyph. `leftBearing` is the offset
    /// from the typographic origin to the leftmost inked pixel
    /// (positive when the glyph is inset from the origin); `width`
    /// is the visible inked width (ink right edge minus ink left
    /// edge). Renderers use these to trim the font's natural side
    /// bearings on chord-symbol accidentals.
    private static func inkBounds(
        _ string: String, font: CTFont
    ) -> (leftBearing: Double, width: Double) {
        let line = ctLine(for: string, font: font)
        let imageBounds = CTLineGetImageBounds(line, nil)
        return (
            leftBearing: Double(imageBounds.origin.x),
            width: Double(imageBounds.width)
        )
    }

    private static func ctLine(
        for string: String, font: CTFont
    ) -> CTLine {
        let attr = NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]
        )
        return CTLineCreateWithAttributedString(
            attr as CFAttributedString
        )
    }
}
