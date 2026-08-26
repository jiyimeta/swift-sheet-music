import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Tempo {
    /// Build a `<Tempo>` element. Inverse of `Tempo.decode(_:)`:
    /// emits `<tempo>` (beats-per-second), an `<offset x= y=>` element
    /// when either coordinate is non-zero, `<visible>0</visible>` when
    /// hidden, and any per-element `TextProperties` overrides.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "tempo", text: formatDouble(beatsPerSecond)),
        ]
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ],
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        return XMLTreeNode(name: "Tempo", children: children)
    }
}
