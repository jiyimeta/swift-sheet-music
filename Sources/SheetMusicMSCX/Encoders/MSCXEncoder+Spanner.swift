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
    private func nextLocationElement(options: MSCXEncoderOptions = .init()) -> XMLTreeNode? {
        let locationChildren = Self.relativeLocationChildren(
            measures: nextMeasuresOffset,
            fractions: nextFractionsOffset,
            options: options,
        )
        guard !locationChildren.isEmpty else { return nil }
        return XMLTreeNode(name: "next", children: [
            XMLTreeNode(name: "location", children: locationChildren),
        ])
    }

    /// The `<measures>` / `<fractions>` children of a relative
    /// `<location>`. `<measures>` is elided at its `0` default, matching
    /// `xml.tag("measures", …, relDefaults.measure())`; `<fractions>` is
    /// written whenever the model holds one, `nil` standing for "MuseScore
    /// elided it".
    ///
    /// Element order differs by target version: v4 emits `<fractions>` then
    /// `<measures>`, matching what MuseScore 4 wrote when this encoder's
    /// spanner fixtures were captured
    /// (`engraving/types/location.cpp::Location::write`); v3 emits
    /// `<measures>` then `<fractions>`, matching MuseScore 3 — and matching
    /// the `<prev>` markers in `slur_ms3_exchangevoices.mscx:252-259`.
    private static func relativeLocationChildren(
        measures: Int,
        fractions: Fraction?,
        options: MSCXEncoderOptions,
    ) -> [XMLTreeNode] {
        let fractionsNode: XMLTreeNode? = fractions.map {
            XMLTreeNode(
                name: "fractions",
                text: "\($0.numerator)/\($0.denominator)",
            )
        }
        let measuresNode: XMLTreeNode? = measures != 0
            ? XMLTreeNode(name: "measures", text: String(measures))
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
        return locationChildren
    }

    /// The begin side of a *chord-anchored* `<Spanner>` — the form MuseScore
    /// nests inside `<Chord>` / `<Rest>` for slurs, written by the spanner
    /// loop at the tail of `TWrite::writeProperties(const ChordRest*, …)`
    /// (`rw/write/twrite.cpp:1093`, loop at `:1135`).
    ///
    /// Unlike `encode(options:)` this never dispatches on `visible`. That
    /// dispatch exists because a *voice-level* end side is modeled as an
    /// invisible `Spanner`; a chord-anchored one never is — `Chord.spanners`
    /// holds begin sides only, since `Chord.decodeChordSpanners` drops the
    /// `<prev>`-only markers and the encoder recomputes them. Here
    /// `<visible>` therefore means what it says, and an invisible slur still
    /// writes its payload.
    ///
    /// `<next>` is emitted even when both offsets are at their defaults —
    /// as the bare `<next/>` the glissando writer also uses. The decoder
    /// keys "this is a begin side" off the presence of `<next>`, so eliding
    /// it would make the slur vanish on the next read.
    func encodeChordAnchoredBegin(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        XMLTreeNode(
            name: "Spanner",
            attributes: ["type": rawType],
            children: [
                payloadElement(options: options),
                nextLocationElement(options: options)
                    ?? XMLTreeNode(name: "next"),
            ],
        )
    }

    /// The end side of a chord-anchored `<Spanner>`: `<prev><location>` whose
    /// offsets are the *negation* of the begin side's `<next>` — the
    /// relative location read back the other way
    /// (`Location::toRelative`, applied from the end element's tick).
    /// MuseScore's own pairs confirm the negation exactly:
    /// `<next>` `measures 1` / `fractions -1/2` against `<prev>`
    /// `measures -1` / `fractions 1/2`
    /// (`slur_ms3_exchangevoices.mscx:205-210` and `:252-259`).
    ///
    /// The caller supplies the already-negated values, because it is the
    /// voice walker — not the spanner — that knows which chord the marker
    /// landed on.
    static func chordAnchoredEndMarker(
        rawType: String,
        measures: Int,
        fractions: Fraction?,
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        XMLTreeNode(
            name: "Spanner",
            attributes: ["type": rawType],
            children: [
                XMLTreeNode(name: "prev", children: [
                    XMLTreeNode(
                        name: "location",
                        children: relativeLocationChildren(
                            measures: measures,
                            fractions: fractions,
                            options: options,
                        ),
                    ),
                ]),
            ],
        )
    }
}
