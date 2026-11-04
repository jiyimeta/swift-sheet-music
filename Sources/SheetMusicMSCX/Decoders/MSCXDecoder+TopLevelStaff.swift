import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Top-level `<Staff id="N">` measure block — id is required at this
/// level; raised in `decode` if missing.
struct MSCXTopLevelStaff {
    let mscxID: String
    let measures: [Measure]
    /// One entry per measure (positionally aligned with `measures`):
    /// the system-level elements lifted out of that measure's
    /// voices during decoding. `originalStaff` is left nil here and
    /// gets stamped during part assembly.
    let systemElementsByMeasure: [[PositionedSystemElement]]
    /// One entry per measure, one entry per element within it —
    /// positionally aligned with `systemElementsByMeasure` — carrying
    /// each lifted element's own `<eid>`. See
    /// `Voice.DecodeResult.systemElementEIDs`.
    let systemElementEIDsByMeasure: [[EID]]
    /// One entry per measure (positionally aligned with `measures`):
    /// that `<Measure>`'s own `<eid>`, decoded unconditionally.
    /// Only the score's first staff's entries are meaningful — see
    /// `Measure.DecodeResult.eid` and `assembleParts`.
    let measureEIDs: [EID]
    /// Every tie side of the staff's notes, addressed by measure too. Ties are paired once the part is assembled
    /// (`assembleParts`): MuseScore ties into the other staves of a part as well as within one.
    var tieSides: [MSCXTieSide] = []
}

extension MSCXTopLevelStaff {
    static func decode(_ node: XMLTreeNode) throws -> MSCXTopLevelStaff {
        guard let id = node.attributes["id"] else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "mscx.staff.missingID",
                    message: "top-level <Staff> missing id attribute",
                    location: "Staff",
                ),
            )
        }
        let measureNodes = node.all("Measure")
            .filter { !Measure.isMultiMeasureRestContainer($0) }
        var measures: [Measure] = []
        var systemElementsByMeasure: [[PositionedSystemElement]] = []
        var systemElementEIDsByMeasure: [[EID]] = []
        var measureEIDs: [EID] = []
        var tieSides: [MSCXTieSide] = []
        for measureNode in measureNodes {
            let result = try Measure.decodeWithSystemElements(measureNode)
            tieSides += result.tieSides.stamped(\.measure, measures.count)
            measures.append(result.measure)
            systemElementsByMeasure.append(result.systemElements)
            systemElementEIDsByMeasure.append(result.systemElementEIDs)
            measureEIDs.append(result.eid)
        }
        return MSCXTopLevelStaff(
            mscxID: id,
            measures: measures,
            systemElementsByMeasure: systemElementsByMeasure,
            systemElementEIDsByMeasure: systemElementEIDsByMeasure,
            measureEIDs: measureEIDs,
            tieSides: tieSides,
        )
    }
}
