import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StaffText {
    /// Build a `<StaffText>` or `<SystemText>` element. Mirrors
    /// `StaffText.decode(_:isSystemText:)` — emits `<text>`, optional
    /// `<color>` (RGBA attributes), optional `<offset>` (xy
    /// attributes), `<visible>0` when hidden, and any per-element
    /// `TextProperties`. The element name flips between `StaffText`
    /// and `SystemText` based on `isSystemText` so the parser routes
    /// to the same struct on the way back.
    func encode(eid: EID, options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        // `<eid>` is the true first child: `TWrite::write(const
        // StaffText*, ...)` / `write(const SystemText*, ...)`
        // (`rw/write/twrite.cpp:2841-2857`, `:3108-3111`) both funnel
        // into `TWrite::writeProperties(const StaffTextBase*, ...)`
        // (`:2867-2895`), whose leading MidiAction/channelSwitch/aeolus/
        // swing writes are all absent for a plain `StaffText` (none of
        // that is modeled here — `Swing`, not `StaffText`, is the
        // carrier with a leading field), so `writeProperties(TextBase*,
        // ..., true)`'s own first act — `writeItemProperties` — is the
        // very first thing written, ahead of `<text>`.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        children.append(
            encodeText(
                text,
                preservedTextMarkup: preservedTextMarkup,
                options: options,
            ),
        )
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(
            name: isSystemText ? "SystemText" : "StaffText",
            children: children,
        )
    }
}
