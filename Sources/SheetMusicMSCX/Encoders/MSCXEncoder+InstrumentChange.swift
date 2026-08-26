import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension InstrumentChange {
    /// Build the `<InstrumentChange>` element.
    ///
    /// Child order mirrors MuseScore's own writer
    /// (`rw/write/twrite.cpp:2128-2137`): the nested `<Instrument>`
    /// first, then `<init>` only when true, then the `TextBase`
    /// properties. Emitting them in that order is what lets the fixture
    /// round-trip through MuseScore Studio unchanged.
    ///
    /// The nested `<Instrument>` reuses the part-level encoder verbatim,
    /// so its full payload — every `<Articulation>` block plus
    /// `<Channel>` — survives without a second implementation.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let instrument {
            children.append(instrument.encode(options: options))
        }
        if isUserInitialized {
            children.append(XMLTreeNode(name: "init", text: "1"))
        }
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ],
            ))
        }
        if let color {
            children.append(XMLTreeNode(
                name: "color",
                attributes: [
                    "r": String(color.red),
                    "g": String(color.green),
                    "b": String(color.blue),
                    "a": String(color.alpha),
                ],
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        children.append(XMLTreeNode(name: "text", text: text))
        return XMLTreeNode(name: "InstrumentChange", children: children)
    }
}
