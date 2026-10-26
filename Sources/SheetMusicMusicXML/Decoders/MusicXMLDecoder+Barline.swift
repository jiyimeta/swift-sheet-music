import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Translates a MusicXML `<barline>` the way MuseScore's `MusicXmlParserPass2::barline` does (`P2:5741-5837`), into
/// either a start or end repeat — a measure flag, which the layout draws — or a `BarLine` at the location, or
/// nothing for a plain regular bar line at a measure's edge, which is the measure boundary itself.
enum MusicXMLBarlineDecoder {
    struct Decoded {
        enum Placement { case start, middle, end }
        let placement: Placement
        /// The bar line drawn at the location, when the style makes one rather than a repeat.
        let inline: BarLine?
        let startRepeat: Bool
        /// The end repeat's count, when the bar line ends a repeat.
        let endRepeatCount: Int?
    }

    static func decode(_ node: XMLTreeNode) -> Decoded {
        let placement: Decoded.Placement = switch node.attributes["location"] ?? "right" {
        case "left": .start
        case "middle": .middle
        default: .end
        }
        let style = node.first("bar-style")?.text ?? ""
        let repeatNode = node.first("repeat")
        let direction = repeatNode?.attributes["direction"] ?? ""
        switch kind(style: style, repeat: direction) {
        case .startRepeat:
            return Decoded(placement: placement, inline: nil, startRepeat: true, endRepeatCount: nil)
        case .endRepeat:
            // `times`, or 2 when it is absent; MuseScore's `String::toInt` reads one that is no number as 0.
            let times = repeatNode?.attributes["times"] ?? ""
            let count = times.isEmpty ? 2 : Int(times) ?? 0
            return Decoded(placement: placement, inline: nil, startRepeat: false, endRepeatCount: count)
        case let .line(subtype):
            // A plain regular bar line is added only mid-measure (`P2:5819`).
            let drawn = style != "regular" || placement == .middle
            let inline = drawn ? BarLine(subtype: subtype) : nil
            return Decoded(placement: placement, inline: inline, startRepeat: false, endRepeatCount: nil)
        case .nothing:
            return Decoded(placement: placement, inline: nil, startRepeat: false, endRepeatCount: nil)
        }
    }

    private enum Kind: Equatable {
        case startRepeat
        case endRepeat
        /// A bar line of MuseScore's `<subtype>` (nil for a normal one).
        case line(String?)
        case nothing
    }

    /// MuseScore's `determineBarLineType` (`P2:5665-5714`): only a light-heavy backward or heavy-light forward bar
    /// line — or a repeat with no style — is a repeat; any other style with a repeat draws its style and repeats
    /// nothing. `none` and the styles MuseScore does not read make no bar line here. `tick` and `short`, which
    /// MuseScore draws as a short normal bar line, keep their names (no model for the span).
    private static func kind(style: String, repeat direction: String) -> Kind {
        switch (style, direction) {
        case ("light-heavy", "backward"), ("", "backward"): .endRepeat
        case ("heavy-light", "forward"), ("", "forward"): .startRepeat
        case ("light-heavy", ""): .line("end")
        case ("heavy-light", ""): .line("reverse-end")
        case ("regular", _): .line(nil)
        case ("dashed", _): .line("dashed")
        case ("dotted", _): .line("dotted")
        case ("light-light", _): .line("double")
        case ("heavy-heavy", _): .line("double-heavy")
        case ("heavy", _): .line("heavy")
        case ("tick", _), ("short", _): .line(style)
        default: .nothing
        }
    }
}
