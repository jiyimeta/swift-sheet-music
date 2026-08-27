import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Note {
    /// Build a `<Note>` element. Emits pitch / tpc / optional
    /// accidental / optional headType, plus `<Spanner type="Tie">`
    /// markers for `tieForward` / `tieBack`, a
    /// `<Spanner type="Glissando">` block when `glissando` is set, and a
    /// `<Spanner type="GuitarBend">` pair for `guitarBend` /
    /// `guitarBendBack` — see `guitarBendSpanners`.
    /// `chordLines` are the owning chord's `ChordLine`s whose
    /// `noteIndex` points at *this* note. MuseScore nests those inside
    /// the `<Note>` (`TWrite::write(const Note*, …)` walks
    /// `chord()->el()` for chord lines matching the note); chord-level
    /// ones stay under `<Chord>`.
    func encode(
        tieForwardEndpoint: TieEndpoint? = nil,
        tieBackEndpoint: TieEndpoint? = nil,
        guitarBendForwardEndpoint: TieEndpoint? = nil,
        guitarBendBackEndpoint: TieEndpoint? = nil,
        options: MSCXEncoderOptions = .init(),
        drumDefaultHead: String? = nil,
        chordLines: [ChordLine] = [],
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let accidental {
            var accChildren: [XMLTreeNode] = [
                XMLTreeNode(name: "subtype", text: accidental.mscxSubtype),
            ]
            if accidentalBracket != .none {
                accChildren.append(XMLTreeNode(
                    name: "bracket",
                    text: String(accidentalBracket.rawValue),
                ))
            }
            // MuseScore writes `<role>` only for USER accidentals; AUTO
            // is the default and omitted, so existing output is unchanged.
            if accidentalRole == .user {
                accChildren.append(XMLTreeNode(
                    name: "role",
                    text: String(accidentalRole.rawValue),
                ))
            }
            children.append(XMLTreeNode(name: "Accidental", children: accChildren))
        }
        if tieForward != nil {
            children.append(tieSpanner(
                side: "next", endpoint: tieForwardEndpoint,
            ))
        }
        if tieBack != nil {
            children.append(tieSpanner(
                side: "prev", endpoint: tieBackEndpoint,
            ))
        }
        if let glissando {
            children.append(glissandoSpanner(glissando))
        }
        appendParentheses(into: &children, targetVersion: options.targetVersion)
        children.append(XMLTreeNode(name: "pitch", text: String(pitch)))
        children.append(XMLTreeNode(name: "tpc", text: String(tpc)))
        if let headType {
            children.append(XMLTreeNode(name: "head", text: headType))
        } else if let drumDefaultHead {
            children.append(XMLTreeNode(name: "head", text: drumDefaultHead))
        }
        appendUserVelocity(into: &children)
        // MuseScore omits `<play>` for the default (true); emit only
        // the muted form. Element order mirrors the writer: after
        // `<head>`. C++: `TWrite::write(const Note*, …)`.
        if !play {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        // Tablature position, immediately after `<play>`: MuseScore's
        // property order is `… USER_VELOCITY, PLAY, TUNING, FRET, STRING,
        // …, HEAD_TYPE, …` (`TWrite::write(const Note*, …)`,
        // `rw/write/twrite.cpp:2378-2380`). `<veloType>` is appended below
        // rather than here because both generations write it far later —
        // MuseScore 3 after `HEAD_TYPE`, MuseScore 4 not at all.
        if let fret {
            children.append(XMLTreeNode(name: "fret", text: String(fret)))
        }
        if let string {
            children.append(XMLTreeNode(name: "string", text: String(string)))
        }
        appendVelocityType(into: &children, targetVersion: options.targetVersion)
        for chordLine in chordLines {
            children.append(chordLine.encode(options: options))
        }
        children.append(contentsOf: guitarBendSpanners(
            forwardEndpoint: guitarBendForwardEndpoint,
            backEndpoint: guitarBendBackEndpoint,
        ))
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Note", children: children)
    }

    /// Append `<velocity>`, skipped at the default of 0.
    ///
    /// Both generations write it in the same slot — between
    /// `HEAD_GROUP` (`<head>`) and `PLAY` (`<play>`) — under different
    /// `Pid` names.
    /// C++: `Note::write` (3.6.2 `libmscore/note.cpp`, `Pid::VELO_OFFSET`)
    ///      and `TWrite::write(const Note*, …)` (`Pid::USER_VELOCITY`).
    private func appendUserVelocity(into children: inout [XMLTreeNode]) {
        guard userVelocity != 0 else { return }
        children.append(XMLTreeNode(name: "velocity", text: String(userVelocity)))
    }

    /// Append `<veloType>`, which both generations write far later than
    /// `<velocity>` — MuseScore 3 emits `Pid::VELO_TYPE` after
    /// `Pid::HEAD_TYPE`, near the tail of the property list, and
    /// MuseScore 4 dropped it from its writer entirely. Hence the split
    /// from `appendUserVelocity`: the two elements are not adjacent.
    ///
    /// Emitted only when there *is* an override — the type is
    /// meaningless without a value, and emitting it unconditionally
    /// would stamp `<veloType>offset</veloType>` onto every note of a
    /// score that came from a 3.x file. It is likewise omitted when it
    /// already matches the target generation's default (`offset` for
    /// `.v3`, `user` for `.v4`), which keeps round-tripped MuseScore 4
    /// files byte-identical.
    private func appendVelocityType(
        into children: inout [XMLTreeNode],
        targetVersion: MSCXVersion,
    ) {
        guard userVelocity != 0 else { return }
        let versionDefault: NoteVelocityType =
            switch targetVersion {
            case .v2, .v3: .offset
            case .v4: .user
            }
        guard velocityType != versionDefault else { return }
        children.append(XMLTreeNode(
            name: "veloType", text: velocityType.mscxToken,
        ))
    }

    private func tieSpanner(side: String, endpoint: TieEndpoint?) -> XMLTreeNode {
        var inner: [XMLTreeNode] = []
        if side == "next" { inner.append(XMLTreeNode(name: "Tie")) }
        var sideChildren: [XMLTreeNode] = []
        if let endpoint {
            sideChildren.append(locationElement(from: endpoint))
        }
        inner.append(XMLTreeNode(name: side, children: sideChildren))
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Tie"],
            children: inner,
        )
    }

    /// Serialize one endpoint's `<location>`. Shared by ties and guitar
    /// bends — MuseScore has a single `Location` reader/writer pair serving
    /// every connector type, neither of which branches on the spanner.
    func locationElement(from endpoint: TieEndpoint) -> XMLTreeNode {
        // Element order matches MuseScore Studio's own writer:
        // `<measures>` precedes `<fractions>`, which precede `<grace>`,
        // which precedes `<notes>` (`TWrite::write(const Location*, …)`,
        // `rw/write/twrite.cpp:2229-2243`). MuseScore's parser appears
        // tolerant of any order, but matching upstream keeps diffs
        // against MuseScore-saved files clean.
        var children: [XMLTreeNode] = []
        switch endpoint.location {
        case let .sameMeasure(fractions):
            // MuseScore elides `<fractions>` when the value is the
            // `Location::relative()` default (`0/1`) — `TWrite::write
            // (const Location*, …)`, `rw/write/twrite.cpp:2238`, calls
            // `xml.tagFraction("fractions", item->frac().reduced(),
            // relDefaults.frac())`, and `relDefaults.frac()` is `0/1`.
            // A same-measure tie's fraction is never actually zero
            // except `TieLocation.graceZeroDelta`, so this only ever
            // fires there — matching upstream byte-for-byte for that
            // case rather than emitting a functionally-equivalent but
            // needlessly explicit `<fractions>0/1</fractions>`.
            if fractions.numerator != 0 {
                children.append(fractionsNode(fractions))
            }
        case let .crossMeasure(measures, fractions):
            children.append(XMLTreeNode(
                name: "measures", text: String(measures),
            ))
            if let fractions {
                children.append(fractionsNode(fractions))
            }
        case let .graceIndexed(index):
            // `<fractions>`/`<measures>` are both zero here too (the
            // grace shares its parent's tick, same as `graceZeroDelta`)
            // and elided the same way; `<grace>` has no zero-elision —
            // its "no value" sentinel is `INT_MIN`, not `0`
            // (`Location::relative()`, `dom/location.h:51`), so index
            // `0` is written explicitly. The exact shape
            // `<next><location><grace>0</grace></location></next>` was
            // directly observed in a genuine MuseScore Studio fixture —
            // `midirenderer_bend_data/bend_release_twice.mscx:135-139`
            // in the upstream engraving test resources — on a
            // `<Spanner type="GuitarBend">`, not a Tie; no Tie-into-
            // grace fixture was found. The shape generalizes because
            // `Location` read/write is spanner-generic — one
            // `TWrite::write(const Location*, …)` (this same function's
            // caller) and one `TRead::read(Location*, …)`
            // (`rw/read460/tread.cpp:3130-3153`) serve every connector
            // type, GuitarBend and Tie alike; neither branches on which
            // spanner it's serializing.
            children.append(XMLTreeNode(name: "grace", text: String(index)))
        case let .graceOfDistantChord(measures, fractions, graceIndex):
            // Same field order and same default elision as the two cases
            // above — `<measures>` then `<fractions>` then `<grace>` — only
            // with all three present at once.
            if let measures {
                children.append(XMLTreeNode(
                    name: "measures", text: String(measures),
                ))
            }
            if let fractions, fractions.numerator != 0 {
                children.append(fractionsNode(fractions))
            }
            children.append(XMLTreeNode(name: "grace", text: String(graceIndex)))
        }
        // `<notes>` elides at its `0` default, so a tie between two
        // notes that share a pitch rank — every tie whose endpoints are
        // both alone in their chords, and most ties between equal-shaped
        // chords — writes exactly what it wrote before this field
        // existed here. See `TieEndpoint`.
        if endpoint.notesDelta != 0 {
            children.append(XMLTreeNode(
                name: "notes", text: String(endpoint.notesDelta),
            ))
        }
        return XMLTreeNode(name: "location", children: children)
    }

    func fractionsNode(_ f: Fraction) -> XMLTreeNode {
        XMLTreeNode(
            name: "fractions",
            text: "\(f.numerator)/\(f.denominator)",
        )
    }

    /// Append notehead-parenthesis elements in the representation matching
    /// the target MuseScore version: rep2 (`<parentheses>` + `<Parenthesis>`)
    /// for `.v4`, rep1 (`<Symbol><name>…</name></Symbol>`) for `.v2`/`.v3`.
    private func appendParentheses(
        into children: inout [XMLTreeNode],
        targetVersion: MSCXVersion,
    ) {
        guard parentheses != .none else { return }
        switch targetVersion {
        case .v4:
            children.append(XMLTreeNode(name: "parentheses", text: parentheses.mscxToken))
            if parentheses.hasLeft {
                children.append(XMLTreeNode(name: "Parenthesis", children: []))
            }
            if parentheses.hasRight {
                children.append(XMLTreeNode(name: "Parenthesis", children: [
                    XMLTreeNode(name: "horizontalDirection", text: "right"),
                ]))
            }
        case .v2, .v3:
            if parentheses.hasLeft {
                children.append(XMLTreeNode(name: "Symbol", children: [
                    XMLTreeNode(name: "name", text: "noteheadParenthesisLeft"),
                ]))
            }
            if parentheses.hasRight {
                children.append(XMLTreeNode(name: "Symbol", children: [
                    XMLTreeNode(name: "name", text: "noteheadParenthesisRight"),
                ]))
            }
        }
    }

    private func glissandoSpanner(_ glissando: Glissando) -> XMLTreeNode {
        // Start-side only — the end note carries no model state, and
        // the decoder ignores `<Spanner type="Glissando">` blocks
        // without a `<Glissando>` payload child.
        XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Glissando"],
            children: [
                glissando.encode(),
                XMLTreeNode(name: "next"),
            ],
        )
    }
}

extension Glissando {
    /// Build the `<Glissando>` payload child of a
    /// `<Spanner type="Glissando">`. Mirrors MuseScore 4's
    /// `TWrite::write(const Glissando*, …)` — uppercase style token,
    /// `easeInSpin` / `easeOutSpin` integers, `subtype` 0/1 for
    /// straight/wavy, optional `<text>`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(
                name: "subtype",
                text: visualType == .wavy ? "1" : "0",
            ),
            XMLTreeNode(name: "glissandoStyle", text: style.mscxToken),
            XMLTreeNode(name: "easeInSpin", text: String(easeIn)),
            XMLTreeNode(name: "easeOutSpin", text: String(easeOut)),
        ]
        if let text, !text.isEmpty {
            children.append(XMLTreeNode(name: "text", text: text))
        }
        return XMLTreeNode(name: "Glissando", children: children)
    }
}

extension Glissando.Style {
    /// MuseScore writes these as ALL-CAPS tokens; the decoder accepts
    /// any case but we mirror the writer's output.
    var mscxToken: String {
        switch self {
        case .chromatic: "CHROMATIC"
        case .diatonic: "DIATONIC"
        case .whiteKeys: "WHITE_KEYS"
        case .blackKeys: "BLACK_KEYS"
        case .portamento: "PORTAMENTO"
        }
    }
}
