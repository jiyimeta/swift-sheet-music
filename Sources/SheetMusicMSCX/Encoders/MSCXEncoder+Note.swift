import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Note {
    /// Build a `<Note>` element. Emits pitch / tpc / optional
    /// accidental / optional headType, plus `<Spanner type="Tie">`
    /// markers for `tieForward` / `tieBack`, a
    /// `<Spanner type="Glissando">` block when `glissando` is set, and a
    /// `<Spanner type="GuitarBend">` pair for `guitarBend` /
    /// `guitarBendBack` — see `guitarBendSpanners` — and a `<Bend>` for
    /// the pre-4.2 `legacyBend`.
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
        appendAccidental(into: &children)
        // The legacy `<Bend>` is an `el()` item, which MuseScore writes
        // immediately after `<Accidental>` and before the tie spanners —
        // `TWrite::write(const Note*, …)` (`rw/write/twrite.cpp:2328-2336`)
        // walks `item->el()` right there. Both generations agree, so this
        // is not branched on `options.targetVersion`.
        if let legacyBend {
            children.append(legacyBend.encode())
        }
        // `<Fingering>` is another `el()` item, so it belongs in the same slot
        // as the legacy `<Bend>`: after `<Accidental>` and before the tie
        // spanners (`TWrite::write(const Note*, …)`, the `writeItems(item->el())`
        // call at `rw/write/twrite.cpp:2462`). Order among el() items is the
        // order they were added, which for a decoded score is source order.
        for fingering in fingerings {
            children.append(fingering.encode(options: options))
        }
        // Note-attached `<Symbol>` is another `el()` item and shares the same
        // writer slot. Parenthesis glyphs are skipped rather than emitted:
        // they belong to `Note.parentheses`, which `appendParentheses`
        // regenerates in the target version's spelling. The decoder already
        // keeps them out of `symbols`, but `symbols` is a `public var`, and
        // emitting one from here would make encode→decode non-idempotent —
        // `decodeParentheses` would read it back as `parentheses`, growing a
        // pair of brackets the model never had.
        for symbol in symbols where !Self.parenthesisSymbolNames.contains(symbol.name) {
            children.append(symbol.encode(options: options))
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
        // `<tpc>` is the concert (sounding) tonal pitch class; `<tpc2>` is the written one, which
        // MuseScore writes only when the two differ — i.e. on a transposing part. The decoder
        // recomputes it from the instrument, so this is write-only; it exists so MuseScore Studio
        // shows the part at written pitch instead of respelling it from scratch.
        // C++: `TWrite::write(const Note*, …)`, `Pid::TPC2`.
        if options.writtenFifthsOffset != 0 {
            children.append(XMLTreeNode(
                name: "tpc2", text: String(tpc + options.writtenFifthsOffset),
            ))
        }
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
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Note", children: children)
    }

    /// Append the `<Accidental>` block, the first thing MuseScore writes
    /// inside a `<Note>`. Split out of `encode` verbatim — same elements,
    /// same order, same elisions — to keep that function within the
    /// package's body-length budget.
    private func appendAccidental(into children: inout [XMLTreeNode]) {
        guard let accidental else { return }
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
        // which precedes `<notes>` — version-independent, because MuseScore
        // has a single `Location` writer serving every connector type and it
        // is unchanged between 3.6.2 (`Location::write`,
        // `libmscore/location.cpp:52-63`) and master
        // (`TWrite::write(const Location*, …)`, `rw/write/twrite.cpp:2229-2243`).
        // `Spanner.relativeLocationChildren` (`MSCXEncoder+Spanner.swift`)
        // writes the same order for the same reason; the two stay separate
        // only because this one also emits `<grace>` / `<notes>`.
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

extension LegacyBend {
    /// Build the `<Bend>` element. Field order mirrors both writers —
    /// points, then the styled properties, then `<play>`, which is written
    /// only when it is false because `writeProperty(Pid::PLAY)` elides the
    /// default. The four styled properties are likewise absent unless the
    /// user overrode them, so an untouched bend writes back as nothing but
    /// its curve.
    /// C++: `TWrite::write(const Bend*, …)` (`rw/write/twrite.cpp:825`),
    /// 3.6.2 `Bend::write` (`libmscore/bend.cpp:285`). The two are
    /// identical, so no target-version branch exists here.
    ///
    /// The point attributes go in as a dictionary, the same way every other
    /// attribute-carrying encoder in this module writes one (see the
    /// `<color r= g= b= a=>` writers): `XMLTreeSerializer` emits attributes
    /// in sorted key order, so the rendered element reads
    /// `<point pitch= time= vibrato=/>` rather than MuseScore's
    /// `time`/`pitch`/`vibrato`. Attribute order carries no meaning in XML
    /// and MuseScore's reader looks each one up by name; byte parity with
    /// Studio's own writer is a stated non-goal of the serializer.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = points.map { point in
            XMLTreeNode(name: "point", attributes: [
                "time": String(point.time),
                "pitch": String(point.pitch),
                "vibrato": String(point.vibrato),
            ])
        }
        if let lineWidth {
            children.append(XMLTreeNode(
                name: "lineWidth", text: formatDouble(lineWidth),
            ))
        }
        if let fontFace {
            children.append(XMLTreeNode(name: "fontFace", text: fontFace))
        }
        if let fontSize {
            children.append(XMLTreeNode(
                name: "fontSize", text: formatDouble(fontSize),
            ))
        }
        if let fontStyle {
            children.append(XMLTreeNode(
                name: "fontStyle", text: String(fontStyle),
            ))
        }
        if !play {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        return XMLTreeNode(name: "Bend", children: children)
    }
}
