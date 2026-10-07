import SheetMusicFoundation
import SheetMusicLayout

/// The faces a score PDF embeds: Bravura for the music and Edwin's four for text (OpenType files, embedded whole), the
/// platform UI face for the notation labels the layout measured in it, and the fonts the host's text engine falls back
/// to for characters neither has — Japanese, most often. On Windows, `ScorePDFFonts.windows()` (in
/// `SheetMusicRenderWindows`) gives all of them as the screen draws them.
public struct ScorePDFFonts: Sendable {
    let smufl: Data
    let roman: Data
    let bold: Data
    let italic: Data
    let boldItalic: Data
    let system: @Sendable (FontWeight, Bool) -> ScorePDFFontFile?
    let fallback: @Sendable (ScorePDFTextLine) -> [ScorePDFFallbackSpan]
    let outlines: @Sendable (Unicode.Scalar, ScorePDFTextStyle) -> ScorePDFGlyphOutline?

    /// - Parameters:
    ///   - system: the file the platform UI face draws from at a weight and slant — the face of
    ///     `DrawProgram.FontID.system` text: part labels, measure numbers, staff names, jumps — asked once for each
    ///     pair the pages use. Without one (the default), that text draws in Edwin at the positions the layout measured
    ///     in the UI face.
    ///   - fallback: for a line of text with characters its face lacks, the parts of it the host draws in another font,
    ///     asked once per line. Without any (the default), such a character is kept as invisible text, so the PDF can
    ///     still be searched for it.
    ///   - outlines: for a character neither its face nor a `fallback` file carries, the outline the host's text engine
    ///     draws it with — for a host whose fallback fonts the PDF may not embed (Android's CJK faces are CFF). Asked
    ///     once per character and style. The outline is filled where the character's invisible text sits, so the PDF
    ///     still finds it. Without one (the default), the character is invisible text alone.
    ///
    /// A file the PDF may not carry — its license forbids embedding, or its outlines are CFF, which only the bundled
    /// faces are embedded with whole — counts as none.
    public init(
        smufl: Data, roman: Data, bold: Data, italic: Data, boldItalic: Data,
        system: @escaping @Sendable (_ weight: FontWeight, _ isItalic: Bool) -> ScorePDFFontFile? = { _, _ in nil },
        fallback: @escaping @Sendable (_ line: ScorePDFTextLine) -> [ScorePDFFallbackSpan] = { _ in [] },
        outlines: @escaping @Sendable (_ scalar: Unicode.Scalar, _ style: ScorePDFTextStyle) -> ScorePDFGlyphOutline?
            = { _, _ in nil },
    ) {
        self.smufl = smufl
        self.roman = roman
        self.bold = bold
        self.italic = italic
        self.boldItalic = boldItalic
        self.system = system
        self.fallback = fallback
        self.outlines = outlines
    }
}

/// The style a character is drawn in, as the writer asks the host for its outline: the line's face family (the
/// platform UI face, or Edwin) and its weight and slant.
public struct ScorePDFTextStyle: Sendable, Hashable {
    /// Text in the platform UI face (`DrawProgram.FontID.system`) rather than Edwin.
    public let isSystemFace: Bool
    public let weight: FontWeight
    public let isItalic: Bool

    public init(isSystemFace: Bool, weight: FontWeight, isItalic: Bool) {
        self.isSystemFace = isSystemFace
        self.weight = weight
        self.isItalic = isItalic
    }
}

/// A character's outline as the host's text engine draws it: closed contours in em units, x from the pen position and
/// y up from the baseline (a 1000-unit font's path divided by 1000, its y negated if the engine's y runs down). The
/// writer scales it by the font size and fills it with the nonzero rule in the current color.
public struct ScorePDFGlyphOutline: Sendable, Hashable {
    public enum Element: Sendable, Hashable {
        case move(x: Double, y: Double)
        case line(x: Double, y: Double)
        /// A quadratic curve to `(x, y)` through the control point `(cx, cy)` — a PDF has none, so it is raised to a
        /// cubic.
        case quad(cx: Double, cy: Double, x: Double, y: Double)
        case cubic(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
        case close
    }

    public let elements: [Element]

    public init(elements: [Element]) {
        self.elements = elements
    }
}

/// A font file the host hands the writer: the platform UI face, or a font its text engine falls back to.
public struct ScorePDFFontFile: Sendable {
    /// Names the file and face across requests — its path, say — so one that many lines use is embedded once.
    public let key: String
    public let data: Data
    /// The face, when `data` is a collection (`.ttc`); 0 otherwise.
    public let faceIndex: Int

    public init(key: String, data: Data, faceIndex: Int = 0) {
        self.key = key
        self.data = data
        self.faceIndex = faceIndex
    }
}

/// One line of a page's text that has characters its face lacks, as the writer asks the host about it.
public struct ScorePDFTextLine: Sendable, Hashable {
    public let text: String
    /// Text in the platform UI face (`DrawProgram.FontID.system`) rather than Edwin.
    public let isSystemFace: Bool
    public let weight: FontWeight
    public let isItalic: Bool
}

/// Part of a line that the host's text engine draws in a font other than the line's own: its UTF-16 range in the line,
/// and that font.
public struct ScorePDFFallbackSpan: Sendable {
    public let utf16Range: Range<Int>
    public let font: ScorePDFFontFile

    public init(utf16Range: Range<Int>, font: ScorePDFFontFile) {
        self.utf16Range = utf16Range
        self.font = font
    }
}
