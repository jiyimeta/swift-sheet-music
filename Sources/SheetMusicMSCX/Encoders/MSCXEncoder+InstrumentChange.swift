import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension InstrumentChange {
    /// Build the `<InstrumentChange>` element.
    ///
    /// Child order follows MuseScore's own writer
    /// (`rw/write/twrite.cpp:2128-2137`): the nested `<Instrument>` first, then
    /// `<init>` only when true, then the `TextBase` properties. The one
    /// deliberate exception is shared `<color>`, which is emitted last to
    /// avoid the upstream reader's `<style>` reset; see
    /// `ElementProperties.mscxTrailingChildren()`.
    ///
    /// The nested `<Instrument>` reuses the part-level encoder verbatim,
    /// so its full payload — every `<Articulation>` block plus
    /// `<Channel>` — survives without a second implementation.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let instrument {
            children.append(instrument.encode(options: options))
        }
        if isUserInitialized {
            children.append(XMLTreeNode(name: "init", text: "1"))
        }
        // `<eid>` sits here: `TWrite::write(const InstrumentChange*,
        // ...)` (`rw/write/twrite.cpp:2128-2137`) writes `<Instrument>`
        // and the conditional `<init>` first, then calls
        // `writeProperties(toTextBase(item), ..., true)`, whose own
        // first act is `writeItemProperties` — ahead of everything
        // `elementProperties.mscxChildren()` and `<text>` below.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        children.append(encodeText(
            text,
            preservedTextMarkup: preservedTextMarkup,
            options: options,
        ))
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "InstrumentChange", children: children)
    }
}
