import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FretDiagram {
    /// Build the `<FretDiagram>` element in MuseScore's storage order.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children += [
            XMLTreeNode(name: "strings", text: String(stringCount)),
            XMLTreeNode(name: "frets", text: String(fretCount)),
        ]
        // `<eid>` sits here, not first: `TWrite::write(const FretDiagram*,
        // ...)` (`rw/write/twrite.cpp:1438-1465`) writes its own properties
        // loop (which includes the strings/frets counts) before calling
        // `writeItemProperties` — the `<eid>` writer — and only THEN writes
        // `<Harmony>` and the `<fretDiagram>` payload; right where
        // `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
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
