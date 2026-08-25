import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Decoder for MSCX `<Rest>` elements. In our model rests are
/// represented as empty `Chord` values, so this returns a `Chord`
/// with `notes: []` and the parsed duration.
enum MSCXRestDecoder {
    static func decode(_ node: XMLTreeNode) throws -> Chord {
        guard let durationText = node.first("durationType")?.text else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "mscx.rest.missingDurationType",
                    message: "Rest missing <durationType>",
                    location: "Rest",
                ),
            )
        }
        let duration = try duration(
            forDurationType: durationText, node: node,
        )
        var rest = Chord(duration: duration, notes: [])
        rest.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return rest
    }

    private static func duration(
        forDurationType type: String, node: XMLTreeNode,
    ) throws -> NoteDuration {
        if type == "measure" {
            // The `<duration>` child is informational under the
            // `.measure` marker model — encoders re-derive it from
            // the containing measure's effective duration. We accept
            // both the MS3+ slash form (`<duration>N/D</duration>`)
            // and the MS2 attribute form (`<duration z="N" n="D"/>`,
            // C++: `Fraction::write` in MuseScore 2 `libmscore/xml.cpp`)
            // by reading-and-discarding either.
            return .measure
        }
        guard let base = NoteDuration(mscxName: type) else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "mscx.rest.unknownDurationType",
                    message: "Rest unknown durationType \"\(type)\"",
                    location: type,
                ),
            )
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        return base.dotted(dots)
    }
}
