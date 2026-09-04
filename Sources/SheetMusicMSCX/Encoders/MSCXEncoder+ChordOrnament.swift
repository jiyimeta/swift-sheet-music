import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ChordOrnament {
    /// Build the `<Ornament>` element. Inverse of `MSCXDecoder+ChordOrnament`.
    ///
    /// Child order follows `TWrite::write(const Ornament*, …)`
    /// (`rw/write/twrite.cpp:815`) and the `Articulation` properties it
    /// delegates to (`:794`): accidentals, then the ornament's own properties,
    /// then `<subtype>`, `<play>`, and `<ornamentStyle>`. MuseScore's reader
    /// dispatches these by tag name, so the order is cosmetic — matching it
    /// keeps a re-saved file diffable against the MuseScore-written original.
    ///
    /// A `nil` field writes no tag at all, mirroring `writeProperty`, which
    /// skips a property equal to its default. That is what makes a bare
    /// `<Ornament><subtype>…</subtype></Ornament>` come back out bare.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        if options.targetVersion == .v3 {
            return encodeAsMuseScore3Articulation()
        }
        var children: [XMLTreeNode] = []
        children += accidentalNodes()
        if let intervalAbove {
            children.append(XMLTreeNode(name: "intervalAbove", text: intervalAbove.mscxToken))
        }
        if let intervalBelow {
            children.append(XMLTreeNode(name: "intervalBelow", text: intervalBelow.mscxToken))
        }
        if let showAccidental {
            children.append(XMLTreeNode(
                name: "ornamentShowAccidental", text: String(showAccidental.rawValue),
            ))
        }
        if let showCueNote {
            children.append(XMLTreeNode(name: "ornamentShowCueNote", text: showCueNote.rawValue))
        }
        if let startOnUpperNote {
            children.append(XMLTreeNode(
                name: "startOnUpperNote", text: startOnUpperNote ? "1" : "0",
            ))
        }
        children.append(XMLTreeNode(name: "subtype", text: kind.mscxToken))
        if let plays {
            children.append(XMLTreeNode(name: "play", text: plays ? "1" : "0"))
        }
        if let ornamentStyle {
            children.append(XMLTreeNode(name: "ornamentStyle", text: ornamentStyle.rawValue))
        }
        children += elementProperties.mscxChildren()
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Ornament", children: children)
    }

    /// The above accidental carries `<placement>above</placement>`; the below
    /// one is written bare, because `PlacementV` defaults to `BELOW`
    /// (`dom/engravingitem.cpp:1689`) and that is the pairing MuseScore's
    /// reader keys off (`rw/read460/tread.cpp:1928`).
    private func accidentalNodes() -> [XMLTreeNode] {
        var nodes: [XMLTreeNode] = []
        if let accidentalAbove {
            nodes.append(XMLTreeNode(name: "Accidental", children: [
                XMLTreeNode(name: "subtype", text: accidentalAbove.mscxSubtype),
                XMLTreeNode(name: "placement", text: "above"),
            ]))
        }
        if let accidentalBelow {
            nodes.append(XMLTreeNode(name: "Accidental", children: [
                XMLTreeNode(name: "subtype", text: accidentalBelow.mscxSubtype),
            ]))
        }
        return nodes
    }

    /// MuseScore 3 has no `Ornament` class: it wrote the same symbols as plain
    /// `<Articulation>` elements, and its reader answers `e.unknown()` to an
    /// `<Ornament>` tag, dropping it whole. Writing the MS3 spelling keeps the
    /// symbol; the ornament-only state — intervals, accidentals, cue note —
    /// has nowhere to live in that generation and is genuinely lost.
    ///
    /// `<visible>` is not ornament-only state, and MuseScore 3 reads it on an
    /// articulation, so it comes along.
    private func encodeAsMuseScore3Articulation() -> XMLTreeNode {
        XMLTreeNode(
            name: "Articulation",
            children: [XMLTreeNode(name: "subtype", text: kind.mscxToken)]
                + elementProperties.mscxChildren(),
        )
    }
}
