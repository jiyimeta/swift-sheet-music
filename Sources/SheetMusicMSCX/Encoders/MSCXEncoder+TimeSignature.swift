import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension TimeSignature {
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // MuseScore writes `<subtype>` FIRST — `TWrite::write(const TimeSig*, …)` emits `Pid::TIMESIG_TYPE`
        // ahead of the item properties and `<sigN>` — and omits it for the default `NORMAL`, so a numeric
        // signature's bytes are unchanged.
        if symbol != .numeric {
            children.append(XMLTreeNode(name: "subtype", text: String(symbol.rawValue)))
        }
        // `<eid>` comes immediately after `<subtype>` (present or not) and
        // before `<sigN>`/`<sigD>`: `TWrite::write(const TimeSig*, …)`
        // (`rw/write/twrite.cpp:3220-3224`) calls `writeItemProperties` —
        // the `<eid>` writer — right after `Pid::TIMESIG_TYPE`. A numeric
        // signature therefore still gets `<eid>` first (no `<subtype>`
        // precedes it), matching `midi01.mscx`'s `<TimeSig><eid>F_F</eid>`;
        // a common-time/cut-time signature gets `<subtype>` first instead.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
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
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "TimeSig", children: children)
    }
}
