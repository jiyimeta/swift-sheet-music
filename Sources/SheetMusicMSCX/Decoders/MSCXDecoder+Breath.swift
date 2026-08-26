import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Breath {
    /// Decode a `<Breath>` element. Unknown `<subtype>` falls back to
    /// `.breathMark(.comma)` with a warning. Missing `<pause>` uses
    /// `Breath.defaultPause(for:)`.
    static func decodeMSCX(_ node: XMLTreeNode) -> Breath {
        // MuseScore (both 3.6.2 and 4.x) writes the kind as <symbol>.
        // Fall back to <subtype> for any older / hand-written files we
        // may already have emitted.
        let rawSubtype = node.first("symbol")?.text
            ?? node.first("subtype")?.text
            ?? ""
        let kind: Breath.Kind
        if let parsed = Breath.Kind.decode(mscxSubtype: rawSubtype) {
            kind = parsed
        } else {
            mscxDecoderWarn(
                code: "mscx.breath.unknownSubtype",
                message: "unknown <Breath><subtype>: \(rawSubtype) — falling back to breathMarkComma",
            )
            kind = .breathMark(.comma)
        }
        let pause: Double? = node.first("pause").flatMap { Double($0.text) }
        var breath = Breath(kind: kind, pause: pause)
        breath.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return breath
    }
}
