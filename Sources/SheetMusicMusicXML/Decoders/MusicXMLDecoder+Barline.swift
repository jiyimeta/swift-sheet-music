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
        case let .line(line):
            // A plain regular bar line is added only mid-measure (`P2:5819`).
            let drawn = style != "regular" || placement == .middle
            return Decoded(placement: placement, inline: drawn ? line : nil, startRepeat: false, endRepeatCount: nil)
        case .nothing:
            return Decoded(placement: placement, inline: nil, startRepeat: false, endRepeatCount: nil)
        }
    }

    private enum Kind: Equatable {
        case startRepeat
        case endRepeat
        case line(BarLine)
        case nothing
    }

    /// MuseScore's `determineBarLineType` (`P2:5665-5714`): only a light-heavy backward or heavy-light forward bar
    /// line — or a repeat with no style — is a repeat; any other style with a repeat draws its style and repeats
    /// nothing. `none` is a hidden normal bar line, and `tick` and `short` are normal ones spanning part of the staff
    /// (`createBarline`, `P2:2047-2063`), whose span the model keeps as the `<spanFromOffset>` / `<spanToOffset>`
    /// MuseScore writes for it but does not draw. A style MuseScore does not read makes no bar line.
    private static func kind(style: String, repeat direction: String) -> Kind {
        switch (style, direction) {
        case ("light-heavy", "backward"), ("", "backward"): .endRepeat
        case ("heavy-light", "forward"), ("", "forward"): .startRepeat
        case ("light-heavy", ""): .line(BarLine(subtype: "end"))
        case ("heavy-light", ""): .line(BarLine(subtype: "reverse-end"))
        case ("regular", _): .line(BarLine())
        case ("dashed", _): .line(BarLine(subtype: "dashed"))
        case ("dotted", _): .line(BarLine(subtype: "dotted"))
        case ("light-light", _): .line(BarLine(subtype: "double"))
        case ("heavy-heavy", _): .line(BarLine(subtype: "double-heavy"))
        case ("heavy", _): .line(BarLine(subtype: "heavy"))
        case ("none", _): .line(BarLine(visible: false))
        // `BARLINE_SPAN_TICK1_FROM` / `_TO` and `BARLINE_SPAN_SHORT1_FROM` / `_TO` (`barline.h`).
        case ("tick", _): .line(spanning(from: -1, to: -7))
        case ("short", _): .line(spanning(from: 2, to: -2))
        default: .nothing
        }
    }

    private static func spanning(from: Int, to: Int) -> BarLine {
        BarLine(preservedMarkup: [
            PreservedXML(name: "spanFromOffset", text: String(from)),
            PreservedXML(name: "spanToOffset", text: String(to)),
        ])
    }
}
