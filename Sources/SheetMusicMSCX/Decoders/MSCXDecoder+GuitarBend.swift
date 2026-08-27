import SheetMusicCore
import SheetMusicXMLTools

extension Note {
    /// The whammy-bar-only properties MuseScore writes for `DIVE`, `PRE_DIVE`,
    /// `DIP` and `SCOOP`. Names are the `xmlName` column of `property.cpp`'s
    /// property table (`dom/property.cpp:450-453`) — note that `VIBRATO_LINE_TYPE`
    /// serializes as `guitarDipTremoloLine`, not as its Pid spelling.
    private static let diveOnlyProperties: Set = [
        "guitarDiveTabPos",
        "guitarDipTremoloLine",
        "guitarDiveIsSlack",
        "guitarBendAmount",
    ]

    /// `<GuitarBend>` children this decoder either models or announces on its
    /// own. Everything else is unmodeled and reported by
    /// `mscx.guitarBend.propertiesDropped`.
    ///
    /// `<direction>` is listed here because it has its own diagnostic
    /// (`mscx.guitarBend.directionDropped`), as do the `diveOnlyProperties`,
    /// which are unioned in rather than repeated.
    private static let guitarBendKnownChildren = diveOnlyProperties.union([
        "guitarBendType",
        "bendStartTimeFactor",
        "bendEndTimeFactor",
        "bendTargetTimeFactor",
        "bendShowHoldLine",
        "GuitarBendHold",
        "direction",
        eidChildName,
        // `<anchor>` is `SLine`'s spanner anchor, not a bend property:
        // `TWrite::write(const GuitarBend*, …)` ends with
        // `writeProperties(static_cast<const SLine*>(item), …)`
        // (`rw/write/twrite.cpp:1568`), which writes `Pid::ANCHOR` (`:1606`)
        // — so every guitar bend MuseScore 4 writes carries `<anchor>3</anchor>`.
        // It holds no user data: the value is constant `Spanner::Anchor::NOTE`
        // for a bend, and this package re-emits it unconditionally on encode
        // (`MSCXEncoder+GuitarBend.swift:108`, and `:115` for the hold line),
        // so nothing is lost. Warning on it would fire on 100% of real MS4
        // bends for a tag that round-trips byte-identically.
        "anchor",
    ])

    /// `<Bend>` children `decodeLegacyBend` models. Everything else is
    /// unmodeled and reported by `mscx.bend.propertiesDropped`.
    private static let legacyBendKnownChildren: Set = [
        "point",
        "play",
        "lineWidth",
        "fontFace",
        "fontSize",
        "fontStyle",
        eidChildName,
    ]

    /// MuseScore 4.6's regenerated internal element id. It is exempt from the
    /// dropped-child diagnostics on purpose: no decoder in this package models
    /// `<eid>` anywhere, it carries no user data (4.6 mints a fresh one on
    /// every save), and warning on it would fire on every element of every 4.6
    /// score — drowning the diagnostics that report real data loss. It stays
    /// silently elided.
    private static let eidChildName = "eid"

    /// The `<direction>` spellings that mean "unchanged", so dropping the tag
    /// loses nothing.
    ///
    /// MuseScore never actually writes one: `writeProperty` hands the value
    /// and `propertyDefault` to `XmlWriter::tagProperty`, which returns
    /// without emitting when they are equal (`rw/write/twrite.cpp:407` →
    /// `rw/xmlwriter.cpp:103`), and `GuitarBend::propertyDefault(Pid::DIRECTION)`
    /// is `DirectionV::AUTO` (`dom/guitarbend.cpp:412`). The tag's presence in
    /// a MuseScore-written file is therefore always a user flip. `"auto"` is
    /// the serialized name of the default (`TConv::toXml(DirectionV)`,
    /// `types/typesconv.cpp:2253`); `"0"` is its raw enum ordinal, elided
    /// defensively for a hand-written or third-party file that spells the
    /// default out numerically.
    private static let defaultDirections: Set = ["auto", "0"]

    /// Announce every child of `node` outside `known` in a single diagnostic,
    /// naming the tags sorted and deduped. Nothing is emitted when all the
    /// children are known.
    ///
    /// The realistic strays are MuseScore's item properties, written for every
    /// element: MS3 `Element::writeProperties` (`libmscore/element.cpp:576`)
    /// emits `autoplace`, `lid`, `linkedMain` / `linked`, `tag`, `placement`,
    /// `z`, `color`, `visible`, `offset` and `track`; MS4
    /// `TWrite::writeItemProperties` (`rw/write/twrite.cpp:550`) emits `eid`,
    /// `autoplace`, `linkedMain` / `linked`, `track`, `offset`, `color`,
    /// `visible` and `z`. None of them are modeled on a bend, so the loss is
    /// reported rather than passed over.
    private static func warnUnknownChildren(
        of node: XMLTreeNode,
        known: Set<String>,
        code: String,
        location: String,
    ) {
        let dropped = Set(node.children.map(\.name)).subtracting(known).sorted()
        guard !dropped.isEmpty else { return }
        mscxDecoderWarn(
            code: code,
            message: "<\(node.name)> children not modeled and dropped: "
                + dropped.joined(separator: ", "),
            location: location,
        )
    }

    /// Report every property a `<GuitarBend>` payload carries that this model
    /// does not hold: the whammy-bar extras, a user-flipped `<direction>`, and
    /// anything outside `guitarBendKnownChildren`.
    ///
    /// Called *before* `decodeGuitarBend`'s `<guitarBendType>` guard, matching
    /// `decodeLegacyBend`, which warns before its own early return. The
    /// invariant both share: report what the payload loses, then decide
    /// whether the element itself survives. Deferring these until after the
    /// guard would make the property report depend on an unrelated failure —
    /// an unrecognized type would silently swallow it, and fixing the type
    /// would then surface a second round of warnings.
    private static func warnDroppedGuitarBendProperties(_ node: XMLTreeNode) {
        if node.children.contains(where: { diveOnlyProperties.contains($0.name) }) {
            mscxDecoderWarn(
                code: "mscx.guitarBend.divePropertiesDropped",
                message: "Whammy-bar bend properties are not modeled yet and were dropped",
                location: "Note/Spanner[GuitarBend]",
            )
        }
        // A `<direction/>` with no text warns too: an empty value is not a
        // recognized `DirectionV` spelling, so it is an unknown override
        // rather than the elided default.
        let direction = node.first("direction")?.text
        if let direction, !defaultDirections.contains(direction) {
            mscxDecoderWarn(
                code: "mscx.guitarBend.directionDropped",
                message: "Bend arc side override <direction> is not modeled — dropped",
                location: "Note/Spanner[GuitarBend]",
            )
        }
        warnUnknownChildren(
            of: node,
            known: guitarBendKnownChildren,
            code: "mscx.guitarBend.propertiesDropped",
            location: "Note/Spanner[GuitarBend]",
        )
    }

    /// Decode a `<GuitarBend>` block — the payload child of the begin side of
    /// a `<Spanner type="GuitarBend">` pair.
    ///
    /// MuseScore's writer emits `<guitarBendType>` (an int of
    /// `GuitarBendType`), `<bendStartTimeFactor>`, `<bendEndTimeFactor>`, an
    /// optional `<bendTargetTimeFactor>`, the `<bendShowHoldLine>` override,
    /// a nested `<GuitarBendHold>` element when a hold line exists, and — for
    /// the whammy types only — the four `diveOnlyProperties`.
    ///
    /// Anything MuseScore omits is at its C++ default, so the fallbacks here
    /// are the C++ defaults rather than zero: 0 for the start factor, 1 for
    /// the end factor, `.auto` for the hold line.
    ///
    /// `<direction>` — which side of the note the arc is drawn on — is not
    /// modeled and is reported by `mscx.guitarBend.directionDropped`. Its
    /// `writeProperty(item, xml, Pid::DIRECTION)` sits *outside* the
    /// `isDive()` block (`rw/write/twrite.cpp:1557`), so any user-flipped bend
    /// carries it, not just a whammy one — which is why it is not in
    /// `diveOnlyProperties`. Model it as a `GuitarBend` field when bend arc
    /// rendering can honor it.
    ///
    /// C++: `TWrite::write(const GuitarBend*, …)` (`rw/write/twrite.cpp:1543`),
    /// `TRead::read(GuitarBend*, …)` (`rw/read460/tread.cpp:2860`).
    static func decodeGuitarBend(_ node: XMLTreeNode) -> GuitarBend? {
        warnDroppedGuitarBendProperties(node)
        guard let rawType = (node.first("guitarBendType")?.text).flatMap(Int.init),
              let type = GuitarBendType(rawValue: rawType)
        else {
            mscxDecoderWarn(
                code: "mscx.guitarBend.unknownType",
                message: "Unknown or missing <guitarBendType> — bend dropped",
                location: "Note/Spanner[GuitarBend]",
            )
            return nil
        }
        let showHoldLine = (node.first("bendShowHoldLine")?.text)
            .flatMap(Int.init)
            .flatMap(GuitarBend.ShowHoldLine.init(rawValue:)) ?? .auto
        return GuitarBend(
            type: type,
            startTimeFactor: (node.first("bendStartTimeFactor")?.text).flatMap(Double.init) ?? 0,
            endTimeFactor: (node.first("bendEndTimeFactor")?.text).flatMap(Double.init) ?? 1,
            targetTimeFactor: (node.first("bendTargetTimeFactor")?.text).flatMap(Double.init),
            showHoldLine: showHoldLine,
            hasHoldLine: node.children.contains { $0.name == "GuitarBendHold" },
        )
    }

    /// Decode a legacy MuseScore 3 `<Bend>` child of `<Note>` — the
    /// pre-4.2 pitch-curve encoding, which MuseScore 3 and 4 write
    /// identically (`TWrite::write(const Bend*, …)`,
    /// `rw/write/twrite.cpp:825`; 3.6.2 `Bend::write`,
    /// `libmscore/bend.cpp:285`).
    ///
    /// Reads the `<point time= pitch= vibrato=>` list, `<play>`, and the
    /// four styled properties (`<lineWidth>`, `<fontFace>`, `<fontSize>`,
    /// `<fontStyle>`) verbatim for byte round-trip. Any other child is an
    /// unmodeled item property (`offset`, `visible`, …); the bend still
    /// decodes, and the loss is announced by `mscx.bend.propertiesDropped` —
    /// see `warnUnknownChildren` for what MuseScore writes there. A point
    /// missing `time` or `pitch` drops the whole element with
    /// `mscx.bend.malformedPoint` — half a curve would lay out and play as a
    /// different bend.
    /// C++: `TRead::read(Bend*, …)` (`rw/read400/tread.cpp:1912`).
    static func decodeLegacyBend(_ node: XMLTreeNode) -> LegacyBend? {
        warnUnknownChildren(
            of: node,
            known: legacyBendKnownChildren,
            code: "mscx.bend.propertiesDropped",
            location: "Note/Bend",
        )
        var points: [LegacyBend.Point] = []
        for pointNode in node.children where pointNode.name == "point" {
            guard let time = pointNode.attributes["time"].flatMap(Int.init),
                  let pitch = pointNode.attributes["pitch"].flatMap(Int.init)
            else {
                mscxDecoderWarn(
                    code: "mscx.bend.malformedPoint",
                    message: "<Bend> point missing time/pitch — bend dropped",
                    location: "Note/Bend",
                )
                return nil
            }
            points.append(LegacyBend.Point(
                time: time,
                pitch: pitch,
                vibrato: pointNode.attributes["vibrato"].flatMap(Int.init) ?? 0,
            ))
        }
        return LegacyBend(
            points: points,
            play: node.first("play")?.text != "0",
            lineWidth: (node.first("lineWidth")?.text).flatMap(Double.init),
            fontFace: node.first("fontFace")?.text,
            fontSize: (node.first("fontSize")?.text).flatMap(Double.init),
            fontStyle: (node.first("fontStyle")?.text).flatMap(Int.init),
        )
    }
}
