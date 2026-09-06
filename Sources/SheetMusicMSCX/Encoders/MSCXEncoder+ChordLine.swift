import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordLine {
    /// Encode as a `<ChordLine>` element. Child order mirrors
    /// `TWrite::write(const ChordLine*, …)`:
    /// subtype → straight → wavy → play → lengthX → lengthY →
    /// ordinary item properties → Path. Shared `<color>` follows as the
    /// universal trailing property.
    ///
    /// MuseScore's `writeProperty` omits a tag whose value equals the
    /// property default, and `xml.tag(name, value, default)` does the
    /// same for the lengths — so `straight` / `wavy` are written only
    /// when true, `play` only when false, and the lengths only when
    /// non-zero. Reproducing those omissions keeps re-encoded files
    /// byte-comparable with MuseScore's own output.
    func encode(options _: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: String(kind.rawValue)),
        ]
        if isStraight {
            children.append(XMLTreeNode(name: "straight", text: "1"))
        }
        if isWavy {
            children.append(XMLTreeNode(name: "wavy", text: "1"))
        }
        if !plays {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        if lengthX != 0 {
            children.append(XMLTreeNode(
                name: "lengthX", text: Self.format(lengthX),
            ))
        }
        if lengthY != 0 {
            children.append(XMLTreeNode(
                name: "lengthY", text: Self.format(lengthY),
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        if hasUserPath {
            children.append(XMLTreeNode(
                name: "Path",
                children: path.map { element in
                    XMLTreeNode(name: "Element", attributes: [
                        "type": String(element.kind.rawValue),
                        "x": Self.format(element.x),
                        "y": Self.format(element.y),
                    ])
                },
            ))
        }
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "ChordLine", children: children)
    }

    /// Render a spatium-unit measurement the way MuseScore's XML writer
    /// does: integral values lose the fractional part, everything else
    /// keeps its shortest round-tripping form.
    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }
}
