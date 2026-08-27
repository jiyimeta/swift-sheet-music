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
    /// ## `<direction>` is dropped without a diagnostic
    ///
    /// `writeProperty(item, xml, Pid::DIRECTION)` sits *outside* the `isDive()`
    /// block (`rw/write/twrite.cpp:1557`), so any user-flipped bend carries it,
    /// not just a whammy one — which is why it is not in `diveOnlyProperties`.
    /// It is deliberately silent rather than announced: the property is purely
    /// which side of the note the bend arc is drawn on, and v1 deliberately
    /// does not model the explicit direction override — the automatic up/down
    /// rule (`bendIsUp` in `LayoutEngine+GuitarBends.swift`) decides the side,
    /// so a hand-flipped bend re-engraves to its automatic side. Because
    /// `DirectionV::AUTO` is the default, the element is absent from every
    /// score nobody hand-flipped — including all six vendored fixtures — so
    /// announcing it would fire on exactly the scores where the drop is least
    /// consequential.
    ///
    /// C++: `TWrite::write(const GuitarBend*, …)` (`rw/write/twrite.cpp:1543`),
    /// `TRead::read(GuitarBend*, …)` (`rw/read460/tread.cpp:2860`).
    static func decodeGuitarBend(_ node: XMLTreeNode) -> GuitarBend? {
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
        if node.children.contains(where: { diveOnlyProperties.contains($0.name) }) {
            mscxDecoderWarn(
                code: "mscx.guitarBend.divePropertiesDropped",
                message: "Whammy-bar bend properties are not modeled yet and were dropped",
                location: "Note/Spanner[GuitarBend]",
            )
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

    /// Announce a legacy MuseScore 3 `<Bend>` child.
    ///
    /// MuseScore 3 encoded guitar bends as a `<Bend>` element holding a
    /// `<point time= pitch=>` curve, entirely unlike the 4.x spanner pair, and
    /// MuseScore 4 converts it on import (`TRead::read` for `Note`,
    /// `rw/read400/tread.cpp:3143`). This decoder models only the 4.x form, so
    /// a `<Bend>` would otherwise vanish without a trace.
    static func warnIfLegacyBend(_ node: XMLTreeNode) {
        guard node.children.contains(where: { $0.name == "Bend" }) else { return }
        mscxDecoderWarn(
            code: "mscx.bend.legacyUnsupported",
            message: "Legacy MuseScore 3 <Bend> is not supported yet — element skipped",
            location: "Note/Bend",
        )
    }
}
