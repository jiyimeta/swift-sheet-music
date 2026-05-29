import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tremolo {
    /// First-pass MSCX decode of a `<Tremolo>` / `<TremoloSingleChord>` /
    /// `<TremoloTwoChord>` child of `<Chord>`. For the MS3-style
    /// `<Tremolo>` tag, `r8/r16/r32` map to `.single` and `c8/c16/c32`
    /// to `.between` (the pairing-validation second pass runs in
    /// `MSCXDecoder+Voice`). For MS4's tag-discriminated form, the tag
    /// name fixes the span and either prefix is accepted in `<subtype>`.
    /// C++: `mu::engraving::TremoloDispatcher::read`,
    /// `TremoloSingleChord::read`, `TremoloTwoChord::read`.
    static func decode(_ node: XMLTreeNode) throws -> Tremolo {
        guard let subtypeText = node.first("subtype")?.text else {
            throw SheetMusicError.malformedScore(
                reason: "\(node.name) missing <subtype>",
            )
        }
        let span: Span
        let subtype: Subtype
        switch node.name {
        case "TremoloSingleChord":
            span = .single
            subtype = try parseBars(subtypeText)
        case "TremoloTwoChord":
            span = .between
            subtype = try parseBars(subtypeText)
        default:
            (subtype, span) = try parseSubtype(subtypeText)
        }
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
        case "r64": return (.r64, .single)
        case "c8": return (.r8, .between)
        case "c16": return (.r16, .between)
        case "c32": return (.r32, .between)
        case "c64": return (.r64, .between)
        default:
            throw SheetMusicError.malformedScore(
                reason: "Tremolo unknown <subtype> \(text)",
            )
        }
    }

    /// MS4 form: the tag name (`TremoloSingleChord` / `TremoloTwoChord`)
    /// already pins the span, so the subtype string only needs to
    /// resolve the bar count. Either the `r*` or `c*` prefix is
    /// accepted defensively since both MS4 readers in upstream
    /// MuseScore route through the same TConv-driven token table.
    private static func parseBars(_ text: String) throws -> Subtype {
        switch text {
        case "r8", "c8": return .r8
        case "r16", "c16": return .r16
        case "r32", "c32": return .r32
        case "r64", "c64": return .r64
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
