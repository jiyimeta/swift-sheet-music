import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Decoder for MSCX `<Rest>` elements. In our model rests are
/// represented as empty `Chord` values, so this returns a `Chord`
/// with `notes: []` and the parsed duration.
enum MSCXRestDecoder {
    /// Every direct `<Rest>` child read by this decoder or by the
    /// MS2 voice demultiplexer. Rests share `Chord.preservedMarkup`.
    /// `duration` on a measure rest is encoder-owned informational
    /// data and is regenerated from the effective measure duration.
    private static let consumedRestChildren: Set = [
        "Spanner", "color", "dots", "duration", "durationType", "offset", "placement", "track", "visible",
    ]

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
        var rest = Chord(
            duration: duration,
            notes: [],
            preservedMarkup: node.preservedMarkup(consuming: consumedRestChildren),
        )
        rest.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        // A slur may begin or end on a rest — MuseScore anchors them to any
        // `ChordRest`, and its writer treats `<Rest>` and `<Chord>` through
        // the same `TWrite::writeProperties(const ChordRest*, …)`. Share the
        // chord helper so the rest path reports the same losses.
        rest.spanners = Chord.decodeChordSpanners(node)
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
