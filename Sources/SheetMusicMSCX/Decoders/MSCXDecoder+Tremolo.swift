import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tremolo {
    /// First-pass MSCX decode of a `<Tremolo>` / `<TremoloSingleChord>` /
    /// `<TremoloTwoChord>` child of `<Chord>`. For the MS3-style
    /// `<Tremolo>` tag, `r8/r16/r32/r64` map to `.single` and
    /// `c8/c16/c32/c64` to `.between` (the pairing-validation second pass
    /// runs in `MSCXDecoder+Voice`). For MS4's tag-discriminated form,
    /// the tag name fixes the span and either prefix is accepted in
    /// `<subtype>`.
    ///
    /// Returns `nil` for non-fatal anomalies (missing or unknown
    /// `<subtype>`) after emitting a `ScoreDiagnostic`. The caller in
    /// `MSCXDecoder+Chord` treats `nil` the same as "no Tremolo child
    /// present".
    /// C++: `mu::engraving::TremoloDispatcher::read`,
    /// `TremoloSingleChord::read`, `TremoloTwoChord::read`.
    static func decode(_ node: XMLTreeNode) -> Tremolo? {
        guard let subtypeText = node.first("subtype")?.text else {
            mscxDecoderWarn(
                code: "mscx.tremolo.missingSubtype",
                message: "\(node.name) missing <subtype> — tremolo dropped",
            )
            return nil
        }
        let span: Span
        let subtype: Subtype
        switch node.name {
        case "TremoloSingleChord":
            guard let bars = parseBars(subtypeText, tagName: node.name) else {
                return nil
            }
            span = .single
            subtype = bars
        case "TremoloTwoChord":
            guard let bars = parseBars(subtypeText, tagName: node.name) else {
                return nil
            }
            span = .between
            subtype = bars
        default:
            guard let pair = parseSubtype(subtypeText) else {
                return nil
            }
            (subtype, span) = pair
        }
        let stroke = parseStrokeStyle(node.first("strokeStyle")?.text ?? "0")
        return Tremolo(subtype: subtype, span: span, strokeStyle: stroke)
    }

    private static func parseSubtype(
        _ text: String,
    ) -> (Subtype, Span)? {
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
            mscxDecoderWarn(
                code: "mscx.tremolo.unknownSubtype",
                message: "Tremolo unknown <subtype> \(text) — tremolo dropped",
            )
            return nil
        }
    }

    /// MS4 form: the tag name (`TremoloSingleChord` / `TremoloTwoChord`)
    /// already pins the span, so the subtype string only needs to
    /// resolve the bar count. Either the `r*` or `c*` prefix is
    /// accepted defensively since both MS4 readers in upstream
    /// MuseScore route through the same TConv-driven token table.
    private static func parseBars(
        _ text: String,
        tagName: String,
    ) -> Subtype? {
        switch text {
        case "r8", "c8": return .r8
        case "r16", "c16": return .r16
        case "r32", "c32": return .r32
        case "r64", "c64": return .r64
        default:
            mscxDecoderWarn(
                code: "mscx.tremolo.unknownSubtype",
                message: "\(tagName) unknown <subtype> \(text) — tremolo dropped",
            )
            return nil
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
