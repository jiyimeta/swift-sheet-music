import Foundation

/// A rehearsal letter / number ("A", "B", "1サビ", …) attached to a
/// position within a voice. Visually drawn once per system above the
/// top staff at the start of the containing measure, often boxed or
/// circled. C++: `mu::engraving::RehearsalMark`.
///
/// MuseScore's runtime `Type` distinction (`Main` / `Additional`) is
/// not serialized in MSCX and is omitted here; both are represented
/// by the same struct, with the visible difference captured by
/// `frame` (and, in future, by font/size when those are wired up).
public struct RehearsalMark: Sendable, Equatable {
    /// Frame around the text. Mirrors MuseScore's `FrameType`
    /// (`engraving/types/types.h`) and MusicXML's `enclosure`
    /// attribute on `<rehearsal>`.
    public enum FrameKind: String, Sendable {
        /// MuseScore `frameType=0` / MusicXML `enclosure="square"`.
        case rectangle
        /// MuseScore `frameType=1` / MusicXML `enclosure="circle"`.
        case circle
        /// MuseScore `frameType=2` / MusicXML `enclosure="none"`.
        case none
    }

    public var text: String
    /// Author-supplied X offset relative to the default placement,
    /// in spatium units.
    public var offsetX: Double
    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down).
    public var offsetY: Double
    /// Author-supplied colour (RGBA 0..255). Nil = inherit the
    /// default text colour.
    public var color: ScoreColor?
    /// Frame around the text. Defaults to `.rectangle`, matching
    /// MuseScore's `Sid::rehearsalMarkFrameType` default.
    public var frame: FrameKind

    public init(
        text: String,
        offsetX: Double = 0,
        offsetY: Double = 0,
        color: ScoreColor? = nil,
        frame: FrameKind = .rectangle
    ) {
        self.text = text
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.color = color
        self.frame = frame
    }
}
