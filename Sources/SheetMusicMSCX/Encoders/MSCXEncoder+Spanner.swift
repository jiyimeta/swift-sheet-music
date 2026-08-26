import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Spanner {
    /// Build a `<Spanner type="X">` element. MuseScore writes spanners
    /// as a *pair* — a begin-side carrying the subtype payload (e.g.
    /// `<Volta>`, `<HairPin/>`, `<Slur/>`) plus a `<next>` location to
    /// the end tick, and an end-side placeholder with only `<prev>`.
    ///
    /// We dispatch on `visible`: a begin-side preserves the payload
    /// (and Volta endings / measures + fractions offsets), an
    /// end-side emits just `<prev/>` so the parser recovers
    /// `visible == false`.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if visible {
            children.append(payloadElement(options: options))
            if let next = nextLocationElement(options: options) {
                children.append(next)
            }
        } else {
            children.append(XMLTreeNode(name: "prev"))
        }
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": rawType],
            children: children,
        )
    }

    /// The begin-side payload child. MuseScore names this child after
    /// the type — `<Volta>…</Volta>`, `<Slur/>`, `<HairPin/>`, etc.
    /// Volta carries `<endings>` (comma-joined ending numbers); other
    /// kinds are emitted as empty placeholders, since the only fields
    /// the decoder recovers from them are positional.
    private func payloadElement(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        // `<beginText>` and `<placement>` are element properties and
        // ride on the payload child for every line-shaped spanner.
        // Both are emitted only when authored, mirroring MuseScore's
        // "write when no longer styled" rule.
        let beginTextNode: [XMLTreeNode] = beginText.map {
            [XMLTreeNode(name: "beginText", text: $0)]
        } ?? []
        let placementNode: [XMLTreeNode] = placement.map {
            [XMLTreeNode(name: "placement", text: $0.rawValue)]
        } ?? []
        let leading = beginTextNode + placementNode
        if kind == .volta, !voltaEndings.isEmpty {
            let endingsText = voltaEndings.map(String.init).joined(separator: ", ")
            return XMLTreeNode(name: rawType, children: leading + [
                XMLTreeNode(name: "endings", text: endingsText),
            ])
        }
        if kind == .hairpin, let hairpin {
            var children: [XMLTreeNode] = leading + [
                XMLTreeNode(name: "subtype", text: String(hairpin.subtype.rawValue)),
            ]
            if let velo = hairpin.veloChange {
                children.append(XMLTreeNode(name: "veloChange", text: String(velo)))
            }
            if hairpin.veloChangeMethod != .normal {
                children.append(XMLTreeNode(
                    name: "veloChangeMethod",
                    text: hairpin.veloChangeMethod.rawValue,
                ))
            }
            return XMLTreeNode(name: rawType, children: children)
        }
        if kind == .ottava, let ottava {
            var children: [XMLTreeNode] = leading + [
                XMLTreeNode(name: "subtype", text: ottava.subtype.rawValue),
            ]
            if let numbersOnly = ottava.numbersOnly {
                children.append(XMLTreeNode(
                    name: "numbersOnly", text: numbersOnly ? "1" : "0",
                ))
            }
            return XMLTreeNode(name: rawType, children: children)
        }
        return XMLTreeNode(name: rawType, children: leading)
    }

    /// `<next><location>…</location></next>`. Returns nil when both
    /// offsets are at their defaults (no end-side anchor needed).
    /// Element order inside `<location>` differs by target version:
    /// v4 emits `<fractions>` then `<measures>`, matching MuseScore 4
    /// (`engraving/types/location.cpp::Location::write`); v3 emits
    /// `<measures>` then `<fractions>`, matching MuseScore 3.
    private func nextLocationElement(options: MSCXEncoderOptions = .init()) -> XMLTreeNode? {
        let fractionsNode: XMLTreeNode? = nextFractionsOffset.map {
            XMLTreeNode(
                name: "fractions",
                text: "\($0.numerator)/\($0.denominator)",
            )
        }
        let measuresNode: XMLTreeNode? = nextMeasuresOffset != 0
            ? XMLTreeNode(name: "measures", text: String(nextMeasuresOffset))
            : nil
        var locationChildren: [XMLTreeNode] = []
        switch options.targetVersion {
        case .v2, .v3:
            if let measuresNode { locationChildren.append(measuresNode) }
            if let fractionsNode { locationChildren.append(fractionsNode) }
        case .v4:
            if let fractionsNode { locationChildren.append(fractionsNode) }
            if let measuresNode { locationChildren.append(measuresNode) }
        }
        guard !locationChildren.isEmpty else { return nil }
        return XMLTreeNode(name: "next", children: [
            XMLTreeNode(name: "location", children: locationChildren),
        ])
    }
}
