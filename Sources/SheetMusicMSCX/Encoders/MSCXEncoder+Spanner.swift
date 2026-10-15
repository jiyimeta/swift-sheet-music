import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Spanner {
    /// Build a `<Spanner type="X">` element. MuseScore writes spanners
    /// as a *pair* — a begin-side carrying the subtype payload (e.g.
    /// `<Volta>`, `<HairPin/>`, `<Slur/>`) plus a `<next>` location to
    /// the end tick, and an end-side placeholder with only `<prev>`.
    ///
    /// We dispatch on `isEndMarker`, never on `visible`: a begin-side
    /// preserves the payload (and Volta endings / measures + fractions
    /// offsets) — a hidden one carrying `<visible>0</visible>` inside it,
    /// as MuseScore writes it — and an end-side emits just `<prev/>` so
    /// the parser recovers `isEndMarker == true`.
    ///
    /// **No `<eid>` here, deliberately.** The `<Spanner type="X">` wrapper
    /// this method builds is not itself an `EngravingItem` — MuseScore's
    /// `ConnectorInfoWriter::write()` (`connectorinfowriter.cpp:52-75`)
    /// writes only the wrapper, the payload item, and `<prev>`/`<next>`; the
    /// identifier lives one level down, on the begin side's payload element
    /// (confirmed against a real file: `guitarbend_tied.mscx:169-171` is
    /// `<Spanner type="Tie">` → `<Tie>` → `<eid>…</eid>`), and the end side
    /// has no payload at all, so it never carries one. This model's
    /// `payloadElement(options:)` already diverges from `TWrite`'s real
    /// per-subtype field order for `Volta`/`HairPin`/`Ottava` (an
    /// established simplification that predates this task), so there is no
    /// single correct position to add `<eid>` to that payload without first
    /// untangling that divergence per subtype — out of scope for this task.
    /// Reverted from an earlier attempt that stamped `<eid>` on the wrapper
    /// itself, which is a shape no MuseScore file ever produces.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if isEndMarker {
            children.append(XMLTreeNode(name: "prev"))
        } else {
            children.append(payloadElement(options: options))
            if let next = nextLocationElement() {
                children.append(next)
            }
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
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
        // `<beginText>` and the shared element properties ride on the payload
        // child for every line-shaped spanner. Authored `<placement>` is
        // emitted from `ElementProperties` under MuseScore's "write when no
        // longer styled" rule.
        // An empty text is omitted, as MuseScore omits it: an empty element would read back as an empty text.
        let lineTexts: [XMLTreeNode] = [("beginText", beginText), ("continueText", continueText), ("endText", endText)]
            .compactMap { name, text in
                guard let text, !text.isEmpty else { return nil }
                return XMLTreeNode(name: name, text: text)
            }
        let leading = lineTexts + elementProperties.mscxChildren()
        let trailing = elementProperties.mscxTrailingChildren()
        if kind == .gradualTempoChange, let gradualTempoChange {
            return gradualTempoChangePayload(gradualTempoChange, leading: leading, trailing: trailing, options: options)
        }
        // Line variants, then the kind's own children, then the children nothing models (`payloadMarkup`), as read;
        // the color stays last.
        let line = lineChildren()
        if kind == .volta, !voltaEndings.isEmpty {
            let endingsText = voltaEndings.map(String.init).joined(separator: ", ")
            var children = leading + line + [XMLTreeNode(name: "endings", text: endingsText)]
            appendPreservedMarkup(payloadMarkup, to: &children, options: options)
            return XMLTreeNode(name: rawType, children: children + trailing)
        }
        if kind == .hairpin, let hairpin {
            var children: [XMLTreeNode] = leading + line + [
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
            // `TWrite::write(const Hairpin*)`: after `<veloChangeMethod>` (`rw/write/twrite.cpp:1683-1697`).
            if let child = hairpin.voiceAssignment.mscxChild(options: options) {
                children.append(child)
            }
            appendPreservedMarkup(payloadMarkup, to: &children, options: options)
            children += trailing
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
            children += trailing
            return XMLTreeNode(name: rawType, children: children)
        }
        var children = leading + line
        appendPreservedMarkup(payloadMarkup, to: &children, options: options)
        return XMLTreeNode(name: rawType, children: children + trailing)
    }

    /// `<GradualTempoChange>` in `TWrite`'s order (`rw/write/twrite.cpp:1651-1661`): the type, a non-default easing,
    /// an explicit factor; then the line texts and element properties, `<play>0</play>` for a muted change, and the
    /// payload's children nothing models, as read.
    private func gradualTempoChangePayload(
        _ change: GradualTempoChangePayload, leading: [XMLTreeNode], trailing: [XMLTreeNode],
        options: MSCXEncoderOptions,
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if change.type != .undefined {
            children.append(XMLTreeNode(name: "tempoChangeType", text: change.type.rawValue))
        }
        if change.easing != .normal {
            children.append(XMLTreeNode(name: "tempoEasingMethod", text: change.easing.rawValue))
        }
        if let factor = change.factor {
            children.append(XMLTreeNode(name: "tempoChangeFactor", text: formatDouble(factor)))
        }
        children += leading
        if !change.playsBack {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        appendPreservedMarkup(change.preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: rawType, children: children + trailing)
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
    /// Unlike `encode(options:)` this never dispatches on the side. That
    /// dispatch exists because a *voice-level* end side is modeled as an
    /// end-marker `Spanner`; a chord-anchored one never is — `Chord.spanners`
    /// holds begin sides only, since `Chord.decodeChordSpanners` drops the
    /// `<prev>`-only markers and the encoder recomputes them. An invisible
    /// slur still writes its payload.
    ///
    /// `<next>` is emitted even when both offsets are at their defaults —
    /// as the bare `<next/>` the glissando writer also uses. The decoder
    /// keys "this is a begin side" off the presence of `<next>`, so eliding
    /// it would make the slur vanish on the next read.
    func encodeChordAnchoredBegin(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [
            payloadElement(options: options),
            nextLocationElement() ?? XMLTreeNode(name: "next"),
        ]
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": rawType],
            children: children,
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
