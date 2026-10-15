import SheetMusicFoundation

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
    /// Mid-score instrument-change instruction ("アコーディオン に").
    /// C++: `mu::engraving::TextStyleType::INSTRUMENT_CHANGE`.
    case instrumentChange
    case pedal
    case chordSymbolA
    case chordSymbolB
    case chordSymbolRomanNumeral
    case header
    case footer
    case pageNumber
    case glissando
    /// Bend-amount label ("full", "1/2", …) on a legacy MuseScore 3
    /// `<Bend>`. C++: `mu::engraving::TextStyleType::BEND`.
    case bend
    /// A marker set at its bar's start — Segno, Coda, Custom. C++: `TextStyleType::REPEAT_LEFT`.
    case repeatLeft
    /// A marker set at its bar's end, and every jump — Fine, To Coda, D.C. al Fine. C++: `TextStyleType::REPEAT_RIGHT`.
    case repeatRight
    /// Expression text ("dolce"). C++: `TextStyleType::EXPRESSION` (`styledef.cpp:1128-1146`).
    case expression
    /// Drum / hand sticking ("R", "L"). C++: `TextStyleType::STICKING` (`styledef.cpp:1633-1651`).
    case sticking
    /// Piano finger number. C++: `TextStyleType::FINGERING` (`styledef.cpp:894-908`).
    case fingering
    /// Left-hand guitar fingering. C++: `LH_GUITAR_FINGERING` (`styledef.cpp:925-939`).
    case lhGuitarFingering
    /// Right-hand guitar fingering (p, i, m, a). C++: `RH_GUITAR_FINGERING` (`styledef.cpp:941-955`).
    case rhGuitarFingering
    /// Circled string number. C++: `STRING_NUMBER` (`styledef.cpp:989-1003`).
    case stringNumber
    /// String-tunings text. C++: `STRING_TUNINGS` (`style/textstyle.cpp:288-306`).
    case stringTunings
    /// Harp pedal diagram, glyph mode. C++: `HARP_PEDAL_DIAGRAM` (`styledef.cpp:1007-1026`).
    case harpPedalDiagram
    /// Harp pedal diagram, text mode. C++: `HARP_PEDAL_TEXT_DIAGRAM` (`styledef.cpp:1028-1046`).
    case harpPedalTextDiagram
    /// The fret-offset number beside a fret diagram. C++: `FRET_DIAGRAM_FRET_NUMBER` (`styledef.cpp:1346-1353`).
    case fretDiagramFretNumber
}

/// Frame around a text element. Mirrors MuseScore's `FrameType`
/// (`engraving/types/types.h`). Used by both `RehearsalMark` and the
/// `TextStyleDefaults` table; the per-element kind on
/// `RehearsalMark` is an alias of this type.
public enum TextFrameType: String, Sendable, Equatable {
    /// MuseScore `FrameType::SQUARE` (mscx `frameType=1`) /
    /// MusicXML `enclosure="square"`.
    case rectangle
    /// MuseScore `FrameType::CIRCLE` (mscx `frameType=2`) /
    /// MusicXML `enclosure="circle"`.
    case circle
    /// MuseScore `FrameType::NO_FRAME` (mscx `frameType=0`).
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
        spatiumDependent: Bool = true,
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
                spatiumDependent: false,
            )
        case .subtitle:
            return TextStyleDefaults(
                face: "Edwin", size: 14, style: [],
                spatiumDependent: false,
            )
        case .composer, .lyricist:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [],
                spatiumDependent: false,
            )
        // Lyrics — Sid::lyricsOdd/EvenFontFace etc.
        case .lyricsOdd, .lyricsEven:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [],
            )
        // Sid::dynamicsFontFace = "Edwin", size 10, italic.
        case .dynamics:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [.italic],
            )
        // Sid::tempoFontFace = "Edwin", size 12, bold.
        case .tempo:
            return TextStyleDefaults(
                face: "Edwin", size: 12, style: [.bold],
            )
        // Sid::rehearsalMarkFontFace = "Edwin", size 14, bold,
        // SQUARE frame, framePadding 0.5.
        case .rehearsalMark:
            return TextStyleDefaults(
                face: "Edwin", size: 14, style: [.bold],
                frameType: .rectangle, framePadding: 0.5,
            )
        case .staffText, .systemText:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [],
            )
        // Sid::instrumentChangeFontFace = "Edwin", size 10, bold
        // (styledef.cpp:1613-1617).
        case .instrumentChange:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [.bold],
            )
        case .pedal:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [],
            )
        // Standard chord symbol style ("A").
        case .chordSymbolA:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [],
            )
        // Jazz chord symbol style ("B") — italic.
        case .chordSymbolB:
            return TextStyleDefaults(
                face: "Edwin", size: 10, style: [.italic],
            )
        // Roman-numeral analysis uses Campania (the dedicated RN font).
        case .chordSymbolRomanNumeral:
            return TextStyleDefaults(
                face: "Campania", size: 12, style: [],
            )
        case .header, .footer:
            return TextStyleDefaults(
                face: "Edwin", size: 9, style: [],
                spatiumDependent: false,
            )
        case .pageNumber:
            return TextStyleDefaults(
                face: "Edwin", size: 11, style: [],
                spatiumDependent: false,
            )
        // Sid::glissandoFontFace = "Edwin", size 8, italic
        // (styledef.cpp:1484-1488).
        case .glissando:
            return TextStyleDefaults(
                face: "Edwin", size: 8, style: [.italic],
            )
        // Sid::bendFontFace = "Edwin", size 8, normal
        // (styledef.cpp:1512-1516).
        case .bend:
            return TextStyleDefaults(
                face: "Edwin", size: 8, style: [],
            )
        // Sid::repeatLeft/RightFontFace = "Edwin", size 10, normal, spatium-dependent (styledef.cpp:1400-1430).
        case .repeatLeft, .repeatRight:
            return TextStyleDefaults(face: "Edwin", size: 10, style: [])
        // Sid::expressionFontFace "Edwin", size 10, italic (styledef.cpp:1128-1132).
        case .expression:
            return TextStyleDefaults(face: "Edwin", size: 10, style: [.italic])
        // Sid::stickingFontFace "Edwin", size 10, normal (styledef.cpp:1633-1637).
        case .sticking:
            return TextStyleDefaults(face: "Edwin", size: 10, style: [])
        // Sid::fingeringFontFace "Edwin", size 8, normal (styledef.cpp:894-898).
        case .fingering:
            return TextStyleDefaults(face: "Edwin", size: 8, style: [])
        // Sid::LHGuitarFingeringFontFace "Edwin", size 8, normal (styledef.cpp:925-929).
        case .lhGuitarFingering:
            return TextStyleDefaults(face: "Edwin", size: 8, style: [])
        // Sid::RHGuitarFingeringFontFace "Edwin", size 8, italic (styledef.cpp:941-945).
        case .rhGuitarFingering:
            return TextStyleDefaults(face: "Edwin", size: 8, style: [.italic])
        // Sid::stringNumberFontFace "Edwin", size 8; frame CIRCLE, padding 0.2 sp (styledef.cpp:989-997).
        case .stringNumber:
            return TextStyleDefaults(face: "Edwin", size: 8, style: [], frameType: .circle, framePadding: 0.2)
        // Sid::stringTuningsFontSize 9, otherwise the staff-text row (styledef.cpp:1005, textstyle.cpp:288-306).
        case .stringTunings:
            return TextStyleDefaults(face: "Edwin", size: 9, style: [])
        // Sid::harpPedalDiagramFontFace "Edwin", size 10, normal (styledef.cpp:1007-1011).
        case .harpPedalDiagram:
            return TextStyleDefaults(face: "Edwin", size: 10, style: [])
        // Sid::harpPedalTextDiagramFontFace "Edwin", size 8, normal (styledef.cpp:1028-1032).
        case .harpPedalTextDiagram:
            return TextStyleDefaults(face: "Edwin", size: 8, style: [])
        // Sid::fretDiagramFretNumberFontSize 6 (styledef.cpp:1346-1353); MuseScore's FreeSans face is not shipped, so
        // the text face stands in for it.
        case .fretDiagramFretNumber:
            return TextStyleDefaults(face: "Edwin", size: 6, style: [])
        }
    }
}
