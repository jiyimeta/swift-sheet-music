import Foundation

/// Identifies a logical text role in MuseScore (dynamics, rehearsal
/// mark, lyrics, …). Each role maps to a `TextStyleDefaults` row that
/// mirrors MuseScore's `Sid::*FontFace / *FontSize / *FontStyle`
/// defaults from `engraving/style/styledef.cpp`.
///
/// Per-element MSCX attributes (`<face>`, `<size>`, `<bold>`,
/// `<italic>`, …) override the role default; the role default itself
/// can also be overridden globally via the `<Style>` block (not yet
/// wired through `ScoreStyle`). C++: `mu::engraving::TextStyleType`
/// (`engraving/types/textstyletype.h`).
public enum TextStyleType: String, Sendable, CaseIterable {
    case title
    case subtitle
    case composer
    case lyricist
    case lyricsOdd
    case lyricsEven
    case dynamics
    case tempo
    case rehearsalMark
    case staffText
    case systemText
    case pedal
    case chordSymbolA
    case chordSymbolB
    case chordSymbolRomanNumeral
    case header
    case footer
    case pageNumber
}

/// Frame around a text element. Mirrors MuseScore's `FrameType`
/// (`engraving/types/types.h`). Used by both `RehearsalMark` and the
/// `TextStyleDefaults` table; the per-element kind on
/// `RehearsalMark` is an alias of this type.
public enum TextFrameType: String, Sendable, Equatable {
    /// MuseScore `FrameType::SQUARE` (mscx `frameType=0`) /
    /// MusicXML `enclosure="square"`.
    case rectangle
    /// MuseScore `FrameType::CIRCLE` (mscx `frameType=1`) /
    /// MusicXML `enclosure="circle"`.
    case circle
    /// MuseScore `FrameType::NO_FRAME` (mscx `frameType=2`).
    case none
}

/// Static defaults for a `TextStyleType` row. Values mirror
/// `engraving/style/styledef.cpp` constants at MuseScore 4.x defaults.
public struct TextStyleDefaults: Sendable, Equatable {
    /// Font family name. "Edwin" for nearly every role; "Campania"
    /// for Roman-numeral chord symbols.
    public var face: String
    /// Font size in **typographic points**. At MuseScore's default
    /// spatium of 1.764 mm ≈ 5 pt, 10 pt ≈ 2.0 sp.
    public var size: Double
    public var style: FontStyleSet
    public var frameType: TextFrameType
    /// Padding inside the frame, in spatium units.
    public var framePadding: Double
    /// Whether the rendered size scales with the score's spatium.
    /// True for staff-attached text (dynamics, lyrics, …) and false
    /// for page chrome (title block, header, footer, page number).
    public var spatiumDependent: Bool

    public init(
        face: String,
        size: Double,
        style: FontStyleSet,
        frameType: TextFrameType = .none,
        framePadding: Double = 0.2,
        spatiumDependent: Bool = true
    ) {
        self.face = face
        self.size = size
        self.style = style
        self.frameType = frameType
        self.framePadding = framePadding
        self.spatiumDependent = spatiumDependent
    }
}

extension TextStyleType {
    /// MuseScore 4 default for this role. Source citations refer to
    /// `engraving/style/styledef.cpp` line numbers.
    public var museScoreDefault: TextStyleDefaults {
        switch self {
        // Title block — fixed point sizes (not spatium-dependent).
        case .title:
            return TextStyleDefaults(
                face: "Edwin", size: 22, style: [],
                spatiumDependent: false
            )
        case .subtitle:
            return TextStyleDefaults(
                face: "Edwin", size: 14, style: [],
                spatiumDependent: false
            )
        case .composer, .lyricist:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [],
                spatiumDependent: false
            )
        // Lyrics — Sid::lyricsOdd/EvenFontFace etc.
        case .lyricsOdd, .lyricsEven:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: []
            )
        // Sid::dynamicsFontFace = "Edwin", size 10, italic.
        case .dynamics:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [.italic]
            )
        // Sid::tempoFontFace = "Edwin", size 12, bold.
        case .tempo:
            return TextStyleDefaults(
                face: "Edwin", size: 12, style: [.bold]
            )
        // Sid::rehearsalMarkFontFace = "Edwin", size 14, bold,
        // SQUARE frame, framePadding 0.5.
        case .rehearsalMark:
            return TextStyleDefaults(
                face: "Edwin", size: 14, style: [.bold],
                frameType: .rectangle, framePadding: 0.5
            )
        case .staffText, .systemText:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: []
            )
        case .pedal:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: []
            )
        // Standard chord symbol style ("A").
        case .chordSymbolA:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: []
            )
        // Jazz chord symbol style ("B") — italic.
        case .chordSymbolB:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [.italic]
            )
        // Roman-numeral analysis uses Campania (the dedicated RN font).
        case .chordSymbolRomanNumeral:
            return TextStyleDefaults(
                face: "Campania", size: 12, style: []
            )
        case .header, .footer:
            return TextStyleDefaults(
                face: "Edwin", size: 9, style: [],
                spatiumDependent: false
            )
        case .pageNumber:
            return TextStyleDefaults(
                face: "Edwin", size: 11, style: [],
                spatiumDependent: false
            )
        }
    }
}
