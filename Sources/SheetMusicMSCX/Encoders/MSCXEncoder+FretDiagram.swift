import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FretDiagram {
    /// Build the `<FretDiagram>` element in MuseScore's storage order.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // `<eid>` is the first child MuseScore itself writes.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children += [
            XMLTreeNode(name: "strings", text: String(stringCount)),
            XMLTreeNode(name: "frets", text: String(fretCount)),
        ]
        children += elementProperties.mscxChildren()
        children += elementProperties.mscxTrailingChildren()
        if let harmony {
            // The embedded chord symbol has no slot of its own — it is a
            // property of this `FretDiagram`, not an `IdentifiedArray`
            // element — so it carries no identifier of its own to persist.
            children.append(harmony.encode(eid: .invalid, options: options))
        }
        children.append(encodeContents())
        // Invariant: nothing follows `<fretDiagram>` except preserved markup.
        // MuseScore's reader skips every later child; its writer puts the old
        // compatibility block there.
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "FretDiagram", children: children)
    }

    private func encodeContents() -> XMLTreeNode {
        var children = strings.map { string in
            var stringChildren: [XMLTreeNode] = []
            if let marker = string.marker {
                stringChildren.append(XMLTreeNode(name: "marker", text: marker.mscxToken))
            }
            stringChildren += string.dots.map { dot in
                XMLTreeNode(
                    name: "dot",
                    attributes: ["fret": String(dot.fret)],
                    text: dot.kind.mscxToken,
                )
            }
            return XMLTreeNode(
                name: "string",
                attributes: ["no": String(string.index)],
                children: stringChildren,
            )
        }
        if let barre {
            children.append(XMLTreeNode(
                name: "barre",
                attributes: [
                    "start": String(barre.startString),
                    "end": String(barre.endString),
                ],
                text: String(barre.fret),
            ))
        }
        return XMLTreeNode(name: "fretDiagram", children: children)
    }
}
