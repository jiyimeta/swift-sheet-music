import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TimeSignature {
    private static let consumedTimeSignatureChildren: Set = [
        "color", "offset", "placement", "showCourtesySig", "sigD", "sigN", "subtype",
        "visible",
    ]

    static func decode(_ node: XMLTreeNode) throws -> TimeSignature {
        guard let nText = node.first("sigN")?.text, let n = Int(nText) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.timeSig.missingSigN",
                message: "TimeSig missing <sigN>",
                location: "TimeSig",
            ))
        }
        guard let dText = node.first("sigD")?.text, let d = Int(dText) else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.timeSig.missingSigD",
                message: "TimeSig missing <sigD>",
                location: "TimeSig",
            ))
        }
        var timeSig = TimeSignature(
            numerator: n, denominator: d,
            symbol: decodeSymbol(node),
            // `<showCourtesySig>` is written only when off, so an absent tag means the courtesy is drawn.
            showCourtesy: (node.first("showCourtesySig")?.text ?? "1") != "0",
            preservedMarkup: node.preservedMarkup(
                consuming: consumedTimeSignatureChildren,
            ),
        )
        timeSig.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return timeSig
    }

    /// `<subtype>` is MuseScore's `TimeSigType`, written only when it is not `NORMAL`
    /// (`TWrite::write(const TimeSig*, …)` emits `Pid::TIMESIG_TYPE` through `writeProperty`, which skips a
    /// property still at its default). Absent therefore means `.numeric`.
    ///
    /// A value outside the enum is drawn as the numbers, with a warning: the meter itself is intact and only
    /// its glyph is unknown, which is the cosmetic-fallback rule rather than a malformed score. It is a
    /// reported drop rather than a silent one because the tag does not survive in preserved markup — it is in
    /// the consumed set, since the recognized values are written back from the model.
    private static func decodeSymbol(_ node: XMLTreeNode) -> TimeSignatureSymbol {
        guard let text = node.first("subtype")?.text else { return .numeric }
        guard let raw = Int(text), let symbol = TimeSignatureSymbol(rawValue: raw) else {
            mscxDecoderWarn(
                code: "mscx.timeSig.unknownSubtype",
                message: "<TimeSig> has unknown <subtype> \"\(text)\"; drawing the numerator over the denominator",
                location: "TimeSig",
            )
            return .numeric
        }
        return symbol
    }
}
