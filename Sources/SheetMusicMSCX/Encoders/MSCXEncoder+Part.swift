import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Part {
    /// Build the `<Part id="...">` declaration block. The `partID`
    /// and per-staff IDs passed in here must match the IDs used
    /// when emitting the top-level `<Staff id="...">` blocks at
    /// `Score.encode()` (otherwise the round-trip parser fails to
    /// pair declarations with bodies). `Score.encode()` synthesises
    /// sequential 1-based integers so `Part.id` from the model is
    /// shadowed by the encoder-assigned value — preserves
    /// MuseScore Studio compatibility for hand-built scores.
    func encodeDeclaration(
        partID: String,
        staffIDs: [String],
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        precondition(
            staffIDs.count == staves.count,
            "staffIDs must match staves count",
        )
        var children: [XMLTreeNode] = []
        for (staff, id) in zip(staves, staffIDs) {
            children.append(staff.encodeDeclaration(staffID: id, options: options))
        }
        // Round-trip MuseScore's `<Part><show>`: only a hidden part carries the
        // element (`<show>0</show>`), matching MuseScore, which omits it when the
        // part is visible (the default). Emitted after the `<Staff>` declarations
        // and before `<trackName>` to mirror MuseScore's child order.
        if !isVisibleInScore {
            children.append(XMLTreeNode(name: "show", text: "0"))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        children.append(instrument.encode(options: options))
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(
            name: "Part",
            attributes: ["id": partID],
            children: children,
        )
    }
}
