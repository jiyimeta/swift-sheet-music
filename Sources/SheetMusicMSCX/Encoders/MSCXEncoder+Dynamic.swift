import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Dynamic {
    /// Build a `<Dynamic>` element. Mirrors `Dynamic.decode(_:)`: `<subtype>`, `<velocity>` (so the default-velocity
    /// table on the decoder side is bypassed — except for an `other-dynamics` at the decoder's stand-in, which in
    /// MuseScore has no velocity and so writes none, `Dynamic::velocity`, `dom/dynamic.cpp:142-145`), `<play>` and
    /// `<veloChangeSpeed>` when they are not MuseScore's defaults — where `TWrite::write(const Dynamic*)` writes them
    /// (`rw/write/twrite.cpp:1294-1304`) —
    /// then the per-element properties, and the dynamic's own `<text>` last, as `TWrite::writeProperties(const
    /// TextBase*)` writes it (`twrite.cpp:1344-1348`). After `<subtype>` is what matters: MuseScore applies a subtype
    /// by resetting the text to the subtype's own (`Dynamic::setDynamicType`, `dom/dynamic.cpp:230-240`).
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [XMLTreeNode(name: "subtype", text: subtype)]
        if subtype != "other-dynamics" || velocity != Dynamic.defaultVelocity(for: subtype) {
            children.append(XMLTreeNode(name: "velocity", text: String(velocity)))
        }
        if !playsBack {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        if velocityChangeSpeed != .normal {
            children.append(XMLTreeNode(name: "veloChangeSpeed", text: velocityChangeSpeed.rawValue))
        }
        // `TWrite::writeProperties(const TextBase*)` opens with `<voiceAssignment>`, right after the dynamic's own
        // properties (`rw/write/twrite.cpp:1320-1325`).
        if let child = voiceAssignment.mscxChild(options: options) {
            children.append(child)
        }
        // `<eid>` sits here, not first: `TWrite::write(const Dynamic*, ...)`
        // (`rw/write/twrite.cpp:1288-1307`) writes `<subtype>`/`<velocity>`
        // (and other unmodeled Dynamic-only properties) before calling
        // `writeProperties(TextBase*, ...)`, whose own first act is
        // `writeItemProperties` — the `<eid>` writer — right where
        // `elementProperties.mscxChildren()` already sits.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        if let text {
            children.append(encodeText(text, preservedTextMarkup: preservedTextMarkup, options: options))
        }
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Dynamic", children: children)
    }
}
