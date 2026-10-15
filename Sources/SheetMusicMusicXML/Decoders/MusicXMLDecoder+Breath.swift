import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Breath {
    /// Decode a `<breath-mark>` notation child. Empty or unknown values fall back to `.breathMark(.comma)`. MusicXML
    /// carries no pause and MuseScore's importer sets none (`addBreath`, `importmusicxmlpass2.cpp:9196`), so the
    /// pause is `Breath.fileDefaultPause(for:)`, the value an absent `<pause>` means in an MSCX file.
    static func decodeMusicXMLBreathMark(_ node: XMLTreeNode) -> Breath {
        let style: Breath.BreathMarkStyle
        switch node.text.trimmingWhitespaceAndNewlines() {
        case "comma", "": style = .comma
        case "tick": style = .tick
        case "upbow": style = .upbow
        case "salzedo": style = .salzedo
        default: style = .comma
        }
        let kind = Breath.Kind.breathMark(style)
        return Breath(kind: kind, pause: Breath.fileDefaultPause(for: kind))
    }

    /// Decode a `<caesura>` notation child. Empty (MusicXML 3.x form has no text content) or unknown values fall back
    /// to `.caesura(.normal)`; MusicXML 4.0's `single` is the single-stroke caesura, as in MuseScore's importer
    /// (`importmusicxmlpass2.cpp:8494-8508`). The pause is the file default, as for a breath mark.
    static func decodeMusicXMLCaesura(_ node: XMLTreeNode) -> Breath {
        let style: Breath.CaesuraStyle
        switch node.text.trimmingWhitespaceAndNewlines() {
        case "normal", "": style = .normal
        case "short": style = .short
        case "thick": style = .thick
        case "curved": style = .curved
        case "single": style = .singleStroke
        default: style = .normal
        }
        let kind = Breath.Kind.caesura(style)
        return Breath(kind: kind, pause: Breath.fileDefaultPause(for: kind))
    }
}
