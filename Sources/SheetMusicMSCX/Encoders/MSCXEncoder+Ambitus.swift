import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Ambitus {
    /// Build the `<Ambitus>` element. Inverse of `MSCXDecoder+Ambitus`.
    ///
    /// Child order follows `TWrite::write(const Ambitus*, ...)`
    /// (`rw/write/twrite.cpp:571`). MuseScore 4.6 writes the small enums as
    /// integer ordinals, so this encoder does the same; `<head>` remains
    /// verbatim because the model deliberately accepts both 4.6 ordinals and
    /// 5.x names. The four pitch/TPC values are always written, while the
    /// default `hasLine == true` is omitted.
    ///
    /// `<Ambitus>` predates every target supported by this encoder, so no
    /// version branch is needed.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let noteHeadGroup {
            children.append(XMLTreeNode(name: "head", text: noteHeadGroup))
        }
        if let noteHeadType {
            children.append(XMLTreeNode(
                name: "headType",
                text: String(noteHeadType.mscxOrdinal),
            ))
        }
        if let mirror {
            children.append(XMLTreeNode(name: "mirror", text: String(mirror.mscxOrdinal)))
        }
        if !hasLine {
            children.append(XMLTreeNode(name: "hasLine", text: "0"))
        }
        if let lineWidth {
            children.append(XMLTreeNode(name: "lineWidth", text: formatDouble(lineWidth)))
        }
        children += [
            XMLTreeNode(name: "topPitch", text: String(topPitch)),
            XMLTreeNode(name: "topTpc", text: String(topTpc)),
            XMLTreeNode(name: "bottomPitch", text: String(bottomPitch)),
            XMLTreeNode(name: "bottomTpc", text: String(bottomTpc)),
        ]
        appendAccidental(topAccidental, wrapperName: "topAccidental", to: &children)
        appendAccidental(bottomAccidental, wrapperName: "bottomAccidental", to: &children)
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Ambitus", children: children)
    }

    private func appendAccidental(
        _ accidental: Accidental?,
        wrapperName: String,
        to children: inout [XMLTreeNode],
    ) {
        guard let accidental else { return }
        children.append(XMLTreeNode(name: wrapperName, children: [
            XMLTreeNode(name: "Accidental", children: [
                XMLTreeNode(name: "subtype", text: accidental.mscxSubtype),
            ]),
        ]))
    }
}
