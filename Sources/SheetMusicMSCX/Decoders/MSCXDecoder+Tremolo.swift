import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tremolo {
    /// First-pass MSCX decode of a `<Tremolo>` child of `<Chord>`.
    /// `r8/r16/r32` map to `.single`; `c8/c16/c32` map to `.between`
    /// (the pairing-validation second pass runs in `MSCXDecoder+Voice`).
    /// C++: `mu::engraving::TremoloDispatcher::read`.
    static func decode(_ node: XMLTreeNode) throws -> Tremolo {
        guard let subtypeText = node.first("subtype")?.text else {
            throw SheetMusicError.malformedScore(
                reason: "Tremolo missing <subtype>",
            )
        }
        let (subtype, span) = try parseSubtype(subtypeText)
        let stroke = parseStrokeStyle(node.first("strokeStyle")?.text ?? "0")
        return Tremolo(subtype: subtype, span: span, strokeStyle: stroke)
    }

    private static func parseSubtype(
        _ text: String,
    ) throws -> (Subtype, Span) {
        switch text {
        case "r8": return (.r8, .single)
        case "r16": return (.r16, .single)
        case "r32": return (.r32, .single)
        case "c8": return (.r8, .between)
        case "c16": return (.r16, .between)
        case "c32": return (.r32, .between)
        default:
            throw SheetMusicError.malformedScore(
                reason: "Tremolo unknown <subtype> \(text)",
            )
        }
    }

    private static func parseStrokeStyle(_ text: String) -> StrokeStyle {
        switch text {
        case "1": return .traditional
        case "2": return .z
        default: return .default
        }
    }
}
