import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Which source tags never become preserved markup.
enum PreservedMarkupPolicy {
    /// Tags dropped on purpose rather than carried through.
    ///
    /// - `eid`: MuseScore's element identity. Both halves of the
    ///   claim this comment used to make here are false — MuseScore
    ///   4.6 does read `<eid>` (`read460.cpp:127`, `tread.cpp:540,
    ///   577-585`) and writes back whatever it read
    ///   (`twrite.cpp:495-511`), it does not regenerate on load. This
    ///   library models `<eid>` for the carriers it gives identity to
    ///   (chords, notes, rests, grace chords, measures, staves,
    ///   parts, most voice- and system-lane element kinds, and
    ///   tuplets — see `EIDPersistenceTests.swift`) and each of those
    ///   encoders writes its own `<eid>` child directly. `eid` stays
    ///   in this never-preserved set anyway, for two reasons: first,
    ///   for a modeled carrier, keeping it out of the preserved bag
    ///   is what stops that carrier's `<eid>` from being emitted
    ///   twice — once from the model, once from `preservedMarkup`
    ///   (`MSCXPreservationGateTests.swift` calls this out per entry
    ///   for every carrier kind that still loses one). Second, for
    ///   every tag this library does NOT give an identity to
    ///   (`Accidental`, `Text`, frame boxes, and the rest audited in
    ///   `MSCXPreservationGateTests.swift`'s `addPermanentLosses`),
    ///   there is nothing in the model to attach a decoded `<eid>`
    ///   to, so it is dropped rather than carried verbatim; MuseScore
    ///   assigns that element a fresh one the next time it reads the
    ///   file back.
    /// - `LastEID`: MuseScore's id-issuing counter (the highest id it
    ///   has ever handed out), not the identity of any element. This
    ///   library neither reads nor writes it.
    /// - `programVersion` / `programRevision`: the encoder writes its
    ///   own values for the format generation it targets, so carrying
    ///   the source's through would contradict the version it just
    ///   declared.
    static let neverPreserved: Set = [
        "eid", "LastEID", "programVersion", "programRevision",
    ]
}

extension XMLTreeNode {
    /// The children this decoder did not consume, as preserved
    /// markup, in source order.
    ///
    /// `consumed` must list every tag the decoder reads, **including
    /// legacy spellings it accepts for older MuseScore generations**
    /// (e.g. both `Spatium` and `spatium`). A tag missing from the
    /// set is emitted twice — once by the encoder and once from
    /// preserved markup — which the preservation gate and the 2-pass
    /// idempotency gate both catch.
    func preservedMarkup(consuming consumed: Set<String>) -> [PreservedXML] {
        children.compactMap { child in
            guard !consumed.contains(child.name),
                  !PreservedMarkupPolicy.neverPreserved.contains(child.name)
            else { return nil }
            return PreservedXML(child)
        }
    }
}

/// Append preserved markup after the children the encoder built
/// itself, skipping any tag the encoder already wrote for this node.
///
/// The skip is what makes the v3 target safe: `<showFrames>`,
/// `<showMargins>`, `<LayerTag>`, and `<currentLayer>` are read by no
/// decoder — so they land in preserved markup — but
/// `MSCXEncoder+Score.swift` SYNTHESIZES them for a v3 target. Without
/// the skip a v3 encode would carry two of each. The rule is that the
/// encoder's own value wins, decided per node and per tag name.
///
/// This also silently absorbs a missing entry in a decoder's consumed
/// set, which would otherwise show up as a double write. That is the
/// safer failure, but it means the preservation gate cannot detect
/// such a drift — `MSCXPreservedMarkupTests.preservedNamesNeverCollide`
/// is what catches it.
func appendPreservedMarkup(
    _ preserved: [PreservedXML],
    to children: inout [XMLTreeNode],
    options: MSCXEncoderOptions,
) {
    guard options.emitPreservedMarkup, !preserved.isEmpty else { return }
    let alreadyWritten = Set(children.map(\.name))
    children.append(contentsOf: preserved.lazy
        .filter { !alreadyWritten.contains($0.name) }
        .map(XMLTreeNode.init(preserved:)))
}

extension PreservedXML {
    /// Deep-copy an XML subtree into the model's inert mirror of it.
    init(_ node: XMLTreeNode) {
        self.init(
            name: node.name,
            attributes: node.attributes,
            text: node.text,
            children: node.children.map(PreservedXML.init),
        )
    }
}

extension XMLTreeNode {
    /// Rebuild the XML subtree a `PreservedXML` was captured from.
    init(preserved: PreservedXML) {
        self.init(
            name: preserved.name,
            attributes: preserved.attributes,
            text: preserved.text,
            children: preserved.children.map(XMLTreeNode.init(preserved:)),
        )
    }
}
