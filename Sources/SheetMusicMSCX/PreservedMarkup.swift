import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Which source tags never become preserved markup.
enum PreservedMarkupPolicy {
    /// Tags dropped on purpose rather than carried through.
    ///
    /// - `eid` / `LastEID`: MuseScore 5's element identity. This
    ///   encoder declares `version="4.60"`, and 4.6 does not use
    ///   `<eid>` at all. Editing a score can duplicate or strand an
    ///   id, and a stale identity is worse than an absent one —
    ///   MuseScore regenerates them on load.
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
