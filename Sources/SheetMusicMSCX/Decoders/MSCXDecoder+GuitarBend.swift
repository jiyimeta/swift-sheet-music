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
    /// which side of the note the bend arc is drawn on, this package does not
    /// render guitar bends at all yet, and `DirectionV::AUTO` is the default,
    /// so the element is absent from every score nobody hand-flipped —
    /// including all six vendored fixtures. Announcing it would fire on
    /// exactly the scores where the drop is least consequential. Model it as a
    /// `GuitarBend` field when bend rendering lands; until then the C++
    /// citation above is the whole story.
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

    /// Decode a legacy MuseScore 3 `<Bend>` child of `<Note>` — the
    /// pre-4.2 pitch-curve encoding, which MuseScore 3 and 4 write
    /// identically (`TWrite::write(const Bend*, …)`,
    /// `rw/write/twrite.cpp:825`; 3.6.2 `Bend::write`,
    /// `libmscore/bend.cpp:285`).
    ///
    /// Reads the `<point time= pitch= vibrato=>` list, `<play>`, and the
    /// four styled properties (`<lineWidth>`, `<fontFace>`, `<fontSize>`,
    /// `<fontStyle>`) verbatim for byte round-trip. Other item
    /// properties (offset, …) are ignored, matching `Note.decode`'s
    /// handling of unknown children. A point missing `time` or `pitch`
    /// drops the whole element with `mscx.bend.malformedPoint` — half a
    /// curve would lay out and play as a different bend.
    /// C++: `TRead::read(Bend*, …)` (`rw/read400/tread.cpp:1912`).
    static func decodeLegacyBend(_ node: XMLTreeNode) -> LegacyBend? {
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
