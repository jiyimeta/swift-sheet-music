import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Translates MusicXML `<barline>` elements into either:
/// - inline `BarLine` VoiceElements (for `location="middle"` and for explicit
///   end-of-measure styled barlines),
/// - start-repeat / end-repeat flags on the enclosing `Measure`, or
/// - no-op for plain regular barlines that MuseScore treats as implicit
///   measure boundaries.
enum MusicXMLBarlineDecoder {
    struct Decoded {
        enum Placement { case start, middle, end }
        let placement: Placement
        let inline: BarLine?
        let startRepeat: Bool
        let endRepeatCount: Int?
    }

    static func decode(_ node: XMLTreeNode) -> Decoded {
        let location = node.attributes["location"] ?? "right"
        let placement: Decoded.Placement
        switch location {
        case "left":   placement = .start
        case "middle": placement = .middle
        default:       placement = .end
        }

        let barStyle = node.first("bar-style")?.text
        let repeatAttr = node.first("repeat")?.attributes["direction"]

        var startRepeat = false
        var endRepeatCount: Int?
        var inline: BarLine?

        switch repeatAttr {
        case "forward":
            startRepeat = true
        case "backward":
            endRepeatCount = 2  // MuseScore defaults to 2 plays when no explicit count.
        default:
            break
        }

        inline = museScoreBarLine(for: barStyle, placement: placement)

        return Decoded(
            placement: placement,
            inline: inline,
            startRepeat: startRepeat,
            endRepeatCount: endRepeatCount
        )
    }

    /// Map MusicXML `bar-style` to an optional MuseScore `<BarLine>`.
    /// `nil` means "no `<BarLine>` emitted" (implicit measure boundary).
    /// `BarLine(subtype: nil)` means "emit an untyped barline" — used for
    /// mid-measure regular barlines that MuseScore preserves verbatim.
    /// Reference: `mu::iex::musicxml::MusicXmlParserPass2::barline`.
    private static func museScoreBarLine(
        for barStyle: String?,
        placement: Decoded.Placement
    ) -> BarLine? {
        guard let barStyle else { return nil }
        switch barStyle {
        case "regular":
            // MuseScore preserves explicit mid-measure regular barlines as
            // `<BarLine>` with an empty subtype. End-of-measure regular
            // barlines are the implicit measure boundary.
            return placement == .middle ? BarLine(subtype: nil) : nil
        case "dotted":      return BarLine(subtype: "dotted")
        case "dashed":      return BarLine(subtype: "dashed")
        case "light-light": return BarLine(subtype: "double")
        case "light-heavy":
            return BarLine(subtype: placement == .end ? "end" : "final")
        case "heavy-light": return BarLine(subtype: "reverse-end")
        case "heavy-heavy": return BarLine(subtype: "heavy")
        case "tick":        return BarLine(subtype: "tick")
        case "short":       return BarLine(subtype: "short")
        case "none":        return nil
        default:            return BarLine(subtype: barStyle)
        }
    }
}
