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
        eid: EID,
        partID: String,
        staffIDs: [String],
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        precondition(
            staffIDs.count == staves.count,
            "staffIDs must match staves count",
        )
        var children: [XMLTreeNode] = []
        // `<eid>` is our own child — MuseScore never writes one for
        // `<Part>` (P4 plan decision 4) — but written first, like
        // every other carrier.
        EIDXML.appendIfNeeded(eid, options: options, to: &children)
        // The 3.02 output has no part-level hide settings; they go into each staff's integer mode instead.
        let legacyHideModes = options.targetVersion == .v4
            ? [] : HideWhenEmptyDecoding.legacyModes(of: self, globalHideEmptyStaves: options.hideEmptyStaves)
        for (index, id) in staffIDs.enumerated() {
            let staff = staves[index]
            children.append(staff.encodeDeclaration(
                eid: staves.eid(at: index), staffID: id, options: options,
                legacyHideMode: legacyHideModes.indices.contains(index) ? legacyHideModes[index] : nil,
            ))
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
        // After `<trackName>`, each only when not the default, as MuseScore 4.6 writes them
        // (`TWrite::write(const Part*)`, rw/write/twrite.cpp:2518-2524).
        if options.targetVersion == .v4 {
            if hideWhenEmpty != .auto {
                children.append(XMLTreeNode(name: "hideWhenEmpty", text: hideWhenEmpty.rawValue))
            }
            if hideStavesWhenIndividuallyEmpty {
                children.append(XMLTreeNode(name: "hideStavesWhenIndividuallyEmpty", text: "1"))
            }
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
