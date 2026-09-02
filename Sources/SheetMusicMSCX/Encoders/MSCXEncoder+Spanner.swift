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
            if let next = nextLocationElement() {
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
        // `<visible>0</visible>`, which `decodeVisible` reads off this same
        // payload child. Unreachable from `encode(options:)` — that one only
        // builds a payload when `visible` is true, because a voice-level end
        // side *is* the invisible case — so this exists for the
        // chord-anchored begin side, where `visible` means what it says and
        // dropping it would silently un-hide a hidden slur.
        //
        // Before `<placement>`, matching MuseScore's property order
        // (`TWrite::writeItemProperties`, `rw/write/twrite.cpp:572-580`,
        // writes `Pid::VISIBLE` ahead of `Pid::PLACEMENT`).
        let visibleNode: [XMLTreeNode] = visible
            ? []
            : [XMLTreeNode(name: "visible", text: "0")]
        let leading = beginTextNode + visibleNode + placementNode
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
    private func nextLocationElement() -> XMLTreeNode? {
        let locationChildren = Self.relativeLocationChildren(
            measures: nextMeasuresOffset,
            fractions: nextFractionsOffset,
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
    /// **`<measures>` before `<fractions>`, in every target version.**
    /// MuseScore has only ever had one `Location` writer and it has always
    /// emitted `staves, voices, measures, fractions, grace, notes`:
    ///
    /// - 3.6.2 `Location::write`, `libmscore/location.cpp:52-63`
    /// - master `TWrite::write(const Location*, …)`,
    ///   `rw/write/twrite.cpp:2229-2243` (`:2237-2238` for these two)
    ///
    /// This encoder used to branch on `options.targetVersion` and emit
    /// `<fractions>` first for `.v4`. That order matched no MuseScore source
    /// of either era, and no fixture in this repository pinned it — every
    /// vendored file carrying `<measures>` is MS3-era and measures-first
    /// (`testVoltaDynamic.mscx`, `testSingleNoteDynamics.mscx`,
    /// `slur_ms3_exchangevoices.mscx:205-210` and `:252-259`). The branch is
    /// gone; both dialects now write what MuseScore writes.
    ///
    /// `Note.locationElement(from:)` (`MSCXEncoder+Note.swift`) is the same
    /// order for the same reason — it serves ties, guitar bends and
    /// glissandos, which share MuseScore's single `Location` reader/writer
    /// pair. The two writers stay separate only because that one also handles
    /// `<grace>` / `<notes>`; their field order is one decision, cited here.
    private static func relativeLocationChildren(
        measures: Int,
        fractions: Fraction?,
    ) -> [XMLTreeNode] {
        var locationChildren: [XMLTreeNode] = []
        if measures != 0 {
            locationChildren.append(
                XMLTreeNode(name: "measures", text: String(measures)),
            )
        }
        if let fractions {
            locationChildren.append(XMLTreeNode(
                name: "fractions",
                text: "\(fractions.numerator)/\(fractions.denominator)",
            ))
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
                nextLocationElement() ?? XMLTreeNode(name: "next"),
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
                        ),
                    ),
                ]),
            ],
        )
    }
}
