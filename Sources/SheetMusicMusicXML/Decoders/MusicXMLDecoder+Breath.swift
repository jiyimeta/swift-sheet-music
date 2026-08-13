import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Breath {
    /// Decode a `<breath-mark>` notation child. Empty or unknown values
    /// fall back to `.breathMark(.comma)`. `pause` defaults via
    /// `Breath.defaultPause(for:)` (MusicXML carries no pause).
    static func decodeMusicXMLBreathMark(_ node: XMLTreeNode) -> Breath {
        let style: Breath.BreathMarkStyle
        switch node.text.trimmingWhitespaceAndNewlines() {
        case "comma", "": style = .comma
        case "tick": style = .tick
        case "upbow": style = .upbow
        case "salzedo": style = .salzedo
        default: style = .comma
        }
        return Breath(kind: .breathMark(style))
    }

    /// Decode a `<caesura>` notation child. Empty (MusicXML 3.x form
    /// has no text content) or unknown values fall back to
    /// `.caesura(.normal)`. `pause` defaults via
    /// `Breath.defaultPause(for:)` (MusicXML carries no pause).
    static func decodeMusicXMLCaesura(_ node: XMLTreeNode) -> Breath {
        let style: Breath.CaesuraStyle
        switch node.text.trimmingWhitespaceAndNewlines() {
        case "normal", "": style = .normal
        case "short": style = .short
        case "thick": style = .thick
        case "curved": style = .curved
        default: style = .normal
        }
        return Breath(kind: .caesura(style))
    }
}
