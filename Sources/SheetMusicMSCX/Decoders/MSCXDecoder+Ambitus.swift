import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Ambitus {
    /// Every direct `<Ambitus>` child this decoder reads. The accidental names
    /// are wrappers around nested `<Accidental>` elements; `Accidental` itself
    /// is not a direct child and must not be consumed here.
    ///
    /// `color`, `offset`, `placement`, and `visible` are consumed because
    /// `ElementProperties(decodingMSCXChildrenOf:)` reads all four. A tag in
    /// this set is excluded from preserved markup, so it may only be listed
    /// once something actually reads it — `placement` was held back until the
    /// shared decoder learned it, which is the commit this line arrived in.
    private static let consumedChildren: Set = [
        "head", "headType", "mirror", "hasLine", "lineWidth",
        "topPitch", "topTpc", "bottomPitch", "bottomTpc",
        "topAccidental", "bottomAccidental", "color", "offset", "placement",
        "visible",
    ]

    /// Decode one `<Ambitus>`.
    ///
    /// Nothing throws: an ambitus is an embellishment under the parser policy,
    /// so malformed optional values degrade rather than failing the score.
    /// MuseScore 4.6 writes integer ordinals for `<headType>` and `<mirror>`;
    /// newer writers may use the corresponding names, and both are accepted.
    static func decode(_ node: XMLTreeNode) -> Ambitus {
        var ambitus = Ambitus(
            topPitch: node.first("topPitch").flatMap { Int($0.text) } ?? 0,
            topTpc: node.first("topTpc").flatMap { Int($0.text) } ?? 0,
            bottomPitch: node.first("bottomPitch").flatMap { Int($0.text) } ?? 0,
            bottomTpc: node.first("bottomTpc").flatMap { Int($0.text) } ?? 0,
            noteHeadGroup: node.first("head")?.text,
            noteHeadType: decodeNoteHeadType(node),
            mirror: decodeMirror(node),
            hasLine: node.first("hasLine").map { $0.text != "0" } ?? true,
            lineWidth: node.first("lineWidth").flatMap { Double($0.text) },
            topAccidental: decodeAccidental(in: node, wrapperName: "topAccidental"),
            bottomAccidental: decodeAccidental(in: node, wrapperName: "bottomAccidental"),
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        ambitus.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return ambitus
    }

    private static func decodeNoteHeadType(_ node: XMLTreeNode) -> NoteHeadType? {
        guard let text = node.first("headType")?.text else { return nil }
        if let ordinal = Int(text) { return NoteHeadType(mscxOrdinal: ordinal) }
        guard let value = NoteHeadType(mscxName: text) else {
            mscxDecoderWarn(
                code: "mscx.ambitus.unsupportedNoteHeadType",
                message: "Unknown <headType> '\(text)' — using the default",
                location: "Ambitus/headType",
            )
            return nil
        }
        return value
    }

    private static func decodeMirror(_ node: XMLTreeNode) -> Mirror? {
        guard let text = node.first("mirror")?.text else { return nil }
        if let ordinal = Int(text) { return Mirror(mscxOrdinal: ordinal) }
        guard let value = Mirror(mscxName: text) else {
            mscxDecoderWarn(
                code: "mscx.ambitus.unsupportedMirror",
                message: "Unknown <mirror> '\(text)' — using the default",
                location: "Ambitus/mirror",
            )
            return nil
        }
        return value
    }

    private static func decodeAccidental(
        in node: XMLTreeNode,
        wrapperName: String,
    ) -> Accidental? {
        guard let accidentalNode = node.first(wrapperName)?.first("Accidental"),
              let subtype = accidentalNode.first("subtype")?.text
        else { return nil }
        guard let accidental = Accidental(mscxSubtype: subtype) else {
            mscxDecoderWarn(
                code: "mscx.ambitus.unsupportedAccidental",
                message: "Unknown <Accidental><subtype> '\(subtype)' — accidental dropped",
                location: "Ambitus/\(wrapperName)/Accidental",
            )
            return nil
        }
        return accidental
    }
}
