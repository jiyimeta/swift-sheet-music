import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Note {
    /// The `<Spanner type="GuitarBend">` children this note contributes: the
    /// begin side when `guitarBend` is set, then the end side when
    /// `guitarBendBack` is. Both can appear on one note — a slight bend puts
    /// them on the same note, and a note in the middle of a bend chain ends
    /// one bend and starts the next (`guitarbend_release_twice.mscx:207-228`).
    ///
    /// Unlike `glissandoSpanner`, which writes a `<next/>` with no
    /// `<location>` because nothing else in this project reads it, both sides
    /// carry a real location. MuseScore Studio needs it on *both*: a `<next>`
    /// or `<prev>` without a `<location>` leaves the endpoint at its
    /// `measure == INT_MIN` sentinel, so `ConnectorInfo::hasNext()` /
    /// `hasPrevious()` (`dom/connector.h:69-70`) are false and the spanner is
    /// dropped on reload. See `TieLocation.graceZeroDelta` for the full trail.
    ///
    /// A `nil` endpoint means the encoder could not name a partner (no
    /// neighbouring chord in this voice). The side is still written, because
    /// omitting it would additionally lose the fact that a bend was there;
    /// MuseScore drops it either way.
    ///
    /// C++: `TWrite::writeSpanners` / `SpannerWriter`
    /// (`rw/write/connectorinfowriter.cpp:103-139`), reached from
    /// `TWrite::write(const Note*, …)` (`rw/write/twrite.cpp:2384-2388`),
    /// which is why the pair sits after the note's property cluster.
    func guitarBendSpanners(
        forwardEndpoint: TieEndpoint?,
        backEndpoint: TieEndpoint?,
    ) -> [XMLTreeNode] {
        var result: [XMLTreeNode] = []
        if let guitarBend {
            result.append(XMLTreeNode(
                name: "Spanner",
                attributes: ["type": "GuitarBend"],
                children: [
                    guitarBend.encode(),
                    guitarBendSide("next", endpoint: forwardEndpoint),
                ],
            ))
        }
        if guitarBendBack {
            result.append(XMLTreeNode(
                name: "Spanner",
                attributes: ["type": "GuitarBend"],
                children: [guitarBendSide("prev", endpoint: backEndpoint)],
            ))
        }
        return result
    }

    private func guitarBendSide(
        _ name: String,
        endpoint: TieEndpoint?,
    ) -> XMLTreeNode {
        XMLTreeNode(
            name: name,
            children: endpoint.map { [locationElement(from: $0)] } ?? [],
        )
    }
}

extension GuitarBend {
    /// The `<GuitarBend>` payload child of the begin side.
    ///
    /// Element order mirrors `TWrite::write(const GuitarBend*, …)`
    /// (`rw/write/twrite.cpp:1543-1578`): bend type, the two time factors, the
    /// optional target factor, the show-hold-line override, then the generic
    /// spanner properties. `<anchor>3</anchor>` is `Spanner::Anchor::NOTE`,
    /// which MuseScore writes on every guitar bend and needs on read to
    /// re-anchor the spanner to a note rather than to a segment; every one of
    /// the six vendored fixtures carries it.
    ///
    /// `<eid>` is deliberately not written: it is MuseScore's own element
    /// identity, which this project does not model, and the reader assigns a
    /// fresh one when it is absent.
    ///
    /// Two properties MuseScore writes are not reproduced, because the model
    /// does not hold them — the decoder announces or documents both:
    /// `<direction>` (a user-flipped bend) and the four whammy-bar-only
    /// `guitarDive*` / `guitarBendAmount` / `guitarDipTremoloLine` values.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "guitarBendType", text: String(type.rawValue)),
            XMLTreeNode(
                name: "bendStartTimeFactor",
                text: FormatG.string(startTimeFactor),
            ),
            XMLTreeNode(
                name: "bendEndTimeFactor",
                text: FormatG.string(endTimeFactor),
            ),
        ]
        if let targetTimeFactor {
            children.append(XMLTreeNode(
                name: "bendTargetTimeFactor",
                text: FormatG.string(targetTimeFactor),
            ))
        }
        if showHoldLine != .auto {
            children.append(XMLTreeNode(
                name: "bendShowHoldLine",
                text: String(showHoldLine.rawValue),
            ))
        }
        children.append(XMLTreeNode(name: "anchor", text: "3"))
        if hasHoldLine {
            // The hold line's own properties are not modeled; MuseScore
            // re-derives them from the bend it hangs off, and the fixtures'
            // `<GuitarBendHold>` carries nothing but `<eid>` and `<anchor>`
            // (`guitarbend_prebend.mscx:314-317`).
            children.append(XMLTreeNode(name: "GuitarBendHold", children: [
                XMLTreeNode(name: "anchor", text: "3"),
            ]))
        }
        return XMLTreeNode(name: "GuitarBend", children: children)
    }
}

extension GuitarBendType {
    /// Whether a bend of this type begins and ends on the *same* note, so both
    /// sides of the spanner pair sit on one `<Note>` and both locations are
    /// the zero delta.
    ///
    /// C++: `Score::addGuitarBend` (`editing/cmd.cpp:1009-1014`) sets
    /// `startElement == endElement` for exactly `SLIGHT_BEND`, `DIP` and
    /// `SCOOP`; the same three are the ones `GuitarBend::findPrecedingBend`
    /// refuses to chain through (`dom/guitarbend.cpp:515-521`).
    var mscxBeginsAndEndsOnSameNote: Bool {
        switch self {
        case .slightBend, .dip, .scoop: true
        case .bend, .preBend, .graceNoteBend, .dive, .preDive: false
        }
    }
}
