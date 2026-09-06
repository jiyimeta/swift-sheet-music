import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TimeSignature {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // MuseScore writes `<subtype>` FIRST — `TWrite::write(const TimeSig*, …)` emits `Pid::TIMESIG_TYPE`
        // ahead of the item properties and `<sigN>` — and omits it for the default `NORMAL`, so a numeric
        // signature's bytes are unchanged.
        if symbol != .numeric {
            children.append(XMLTreeNode(name: "subtype", text: String(symbol.rawValue)))
        }
        children += [
            XMLTreeNode(name: "sigN", text: String(numerator)),
            XMLTreeNode(name: "sigD", text: String(denominator)),
        ]
        // MuseScore writes `<showCourtesySig>` after `<sigN>`/`<sigD>` and only when the courtesy is off
        // (`TWrite::write(const TimeSig*, …)`), so the default omits the tag and existing fixtures stay
        // byte-stable.
        if !showCourtesy {
            children.append(XMLTreeNode(name: "showCourtesySig", text: "0"))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "TimeSig", children: children)
    }
}
