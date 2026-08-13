import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Encoder-internal description of a Tie spanner's `<location>`
/// payload. MuseScore Studio interprets this in two distinct ways
/// depending on whether `<measures>` is present:
///
/// * `.sameMeasure(fractions:)` — emits `<location><fractions>F</fractions></location>`,
///   except when `F` is exactly `0/1` (`TieLocation.graceZeroDelta`), where the
///   `<fractions>` child itself is elided, matching MuseScore's own default-value
///   elision — see `graceZeroDelta`'s doc comment. MuseScore reads the fraction (present
///   or implied `0/1`) as a tick delta from the source position to the destination
///   position within the same measure.
///
/// * `.crossMeasure(measures:fractions:)` — emits
///   `<location><measures>M</measures><fractions>F</fractions></location>`
///   (fractions omitted when nil). MuseScore reads this as
///   `(measure delta, position-within-target-measure)`. The
///   `<measures>` token is what disambiguates "this tie crosses a
///   bar line" — without it, MuseScore matches the wrong chord on
///   the source side of the bar, which is what produced the
///   m21→m23 cross-wired ties in `test_export9.mscx`.
enum TieLocation {
    case sameMeasure(fractions: Fraction)
    case crossMeasure(measures: Int, fractions: Fraction?)

    /// The location for a tie between a grace note and a note of its
    /// own parent chord (in either direction) — the single most common
    /// grace tie, e.g. a tied acciaccatura into its main note.
    ///
    /// A grace chord shares its parent chord's tick — MuseScore's
    /// writer never advances the cursor for a grace item
    /// (`if (!item->isGrace()) { … ctx.incCurTick(t); }`,
    /// `rw/write/twrite.cpp:1126-1130`) because `EngravingItem::tick()`
    /// (`dom/engravingitem.cpp:584-596`) resolves through the enclosing
    /// `Segment`, which a grace chord shares with the chord it
    /// decorates. So the tie's source and destination ticks are
    /// identical: zero delta, same measure.
    ///
    /// This is `.sameMeasure(fractions: 0/1)` rather than a distinct
    /// case because MuseScore's own `SpannerWriter` (`dom/connector.cpp`
    /// `SpannerWriter::SpannerWriter`, `~103-138`) prefers computing a
    /// tie's `<location>` from its actual start/end elements via
    /// `Location::fillForElement` (`dom/location.cpp:128-139`) over any
    /// tie-specific special-casing — reusing the ordinary same-measure
    /// path is what "prefer this source of information" means in
    /// practice for a grace tie.
    ///
    /// Verified this is not merely a formatting nicety: MuseScore's
    /// reader treats an *absent* `<location>` under `<next>`/`<prev>`
    /// as "position unknown" (`ConnectorInfoReader::readEndpointLocation`,
    /// `rw/read460/connectorinforeader.cpp:120-132`, leaves the
    /// `Location` at its `measure == INT_MIN` sentinel when no
    /// `<location>` child is present), and `hasNext()` / `hasPrevious()`
    /// (`dom/connector.h:69-70`) test exactly that sentinel. A
    /// location-less `<next/>` therefore makes both `isStart()` and
    /// `isEnd()` false, so `ConnectorInfoReader::readAddConnector(Note*,
    /// …)` (`rw/read460/connectorinforeader.cpp:365-425`) never wires
    /// the parsed `Tie` object to a start/end note at all — the tie is
    /// silently dropped on reload by MuseScore Studio. Emitting an
    /// explicit (even all-zero) `<location>` is what keeps `hasNext()`
    /// true (`Location::relative()` defaults `measure` to `0`, not
    /// `INT_MIN` — `dom/location.h:51`), so the grace note's tie
    /// reconnects correctly.
    static let graceZeroDelta = TieLocation.sameMeasure(
        fractions: Fraction(numerator: 0, denominator: 1),
    )
}

extension Note {
    /// Build a `<Note>` element. Emits pitch / tpc / optional
    /// accidental / optional headType, plus `<Spanner type="Tie">`
    /// markers for `tieForward` / `tieBack` and a
    /// `<Spanner type="Glissando">` block when `glissando` is set.
    /// `chordLines` are the owning chord's `ChordLine`s whose
    /// `noteIndex` points at *this* note. MuseScore nests those inside
    /// the `<Note>` (`TWrite::write(const Note*, …)` walks
    /// `chord()->el()` for chord lines matching the note); chord-level
    /// ones stay under `<Chord>`.
    func encode(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
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
                side: "next", location: tieForwardLocation,
            ))
        }
        if tieBack != nil {
            children.append(tieSpanner(
                side: "prev", location: tieBackLocation,
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
        appendVelocityType(into: &children, targetVersion: options.targetVersion)
        for chordLine in chordLines {
            children.append(chordLine.encode(options: options))
        }
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

    private func tieSpanner(side: String, location: TieLocation?) -> XMLTreeNode {
        var inner: [XMLTreeNode] = []
        if side == "next" { inner.append(XMLTreeNode(name: "Tie")) }
        var sideChildren: [XMLTreeNode] = []
        if let location {
            sideChildren.append(locationElement(from: location))
        }
        inner.append(XMLTreeNode(name: side, children: sideChildren))
        return XMLTreeNode(
            name: "Spanner",
            attributes: ["type": "Tie"],
            children: inner,
        )
    }

    private func locationElement(from location: TieLocation) -> XMLTreeNode {
        // Element order matches MuseScore Studio's own writer:
        // `<measures>` precedes `<fractions>`. MuseScore's parser
        // appears tolerant of either order, but matching upstream
        // keeps diffs against MuseScore-saved files clean.
        var children: [XMLTreeNode] = []
        switch location {
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
        }
        return XMLTreeNode(name: "location", children: children)
    }

    private func fractionsNode(_ f: Fraction) -> XMLTreeNode {
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
