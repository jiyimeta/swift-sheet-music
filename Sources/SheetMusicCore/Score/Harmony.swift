import Foundation

/// Chord symbol attached to a voice position. Source of truth for
/// rendering is `name`; the TPC/case fields are preserved so future
/// transposition / playback work can use them without re-parsing.
///
/// C++: `mu::engraving::Harmony` (`engraving/dom/harmony.cpp`).
public struct Harmony: Sendable, Equatable {
    /// Display string. Rendered with ASCII `b` / `#` substituted by
    /// Bravura SMuFL accidentals at layout time.
    public var name: String
    public var harmonyType: HarmonyType
    /// Root tonal-pitch-class. `nil` ↔ MuseScore `TPC_INVALID` (-1).
    public var rootTpc: Int?
    public var rootCase: NoteCase
    /// Slash-bass TPC. `nil` ↔ MuseScore `TPC_INVALID` (-1). MSCX
    /// spells the field as `<base>` (historical) — not `<bass>`.
    public var bassTpc: Int?
    public var bassCase: NoteCase
    public var leftParen: Bool
    public var rightParen: Bool
    /// MuseScore preserves a per-symbol playback flag. We keep it
    /// for future MIDI realisation; the default renderer ignores it.
    public var play: Bool
    /// Author-supplied X offset (spatium units).
    public var offsetX: Double
    /// Author-supplied Y offset (spatium units, positive = down).
    public var offsetY: Double
    /// Author-supplied colour (RGBA 0..255). Nil = inherit.
    public var color: ScoreColor?
    /// Per-element font overrides. `nil`-fields inherit from
    /// `styleType`'s row in `TextStyleDefaults`.
    public var properties: TextProperties

    public init(
        name: String,
        harmonyType: HarmonyType = .standard,
        rootTpc: Int? = nil,
        rootCase: NoteCase = .auto,
        bassTpc: Int? = nil,
        bassCase: NoteCase = .auto,
        leftParen: Bool = false,
        rightParen: Bool = false,
        play: Bool = true,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        properties: TextProperties = TextProperties()
    ) {
        self.name = name
        self.harmonyType = harmonyType
        self.rootTpc = rootTpc
        self.rootCase = rootCase
        self.bassTpc = bassTpc
        self.bassCase = bassCase
        self.leftParen = leftParen
        self.rightParen = rightParen
        self.play = play
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.color = color
        self.properties = properties
    }

    /// The `TextStyleType` row this element inherits from. Roman
    /// numerals use Campania (`.chordSymbolRomanNumeral`); Standard
    /// and Nashville share `.chordSymbolA` (Edwin 10 pt).
    public var styleType: TextStyleType {
        switch harmonyType {
        case .standard, .nashville: .chordSymbolA
        case .roman: .chordSymbolRomanNumeral
        }
    }
}

/// MSCX `<harmonyType>` enum (0=Standard / 1=Roman / 2=Nashville).
public enum HarmonyType: String, Sendable, Equatable {
    case standard
    case roman
    case nashville
}

/// MSCX `<rootCase>` / `<baseCase>` enum
/// (0=auto / 1=upper / 2=lower / 3=capitalize).
public enum NoteCase: String, Sendable, Equatable {
    case auto
    case upper
    case lower
    case capitalize
}
