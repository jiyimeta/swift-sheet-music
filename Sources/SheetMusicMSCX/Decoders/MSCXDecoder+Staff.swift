import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Decodes the `<StaffType>` / `<defaultClef>` / `<bracket>`
    /// portion of an inside-`<Part><Staff>` element. Measures are
    /// added separately during pairing — see
    /// `assembleParts(decoded:topLevel:)`.
    static func declared(_ node: XMLTreeNode) -> (mscxID: String?, staff: Staff) {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        // Default clef. MuseScore writes one of three forms (see
        // engraving/rw/read460/tread.cpp:3948-3955):
        //   * `<defaultClef>X</defaultClef>` — sets BOTH concert &
        //     transposing to X.
        //   * `<defaultConcertClef>X</defaultConcertClef>` — concert only.
        //   * `<defaultTransposingClef>X</defaultTransposingClef>` —
        //     transposing only.
        // Concert pitch mode is OFF by default in MuseScore, so the
        // displayed clef is the transposing one. We collapse to a
        // single `defaultClefType` here, preferring (in order):
        // explicit defaultClef → defaultTransposingClef → defaultConcertClef.
        // This fixes scores like a contrabass part that only declares
        // `<defaultConcertClef>F8vb</defaultConcertClef>` and
        // `<defaultTransposingClef>F</defaultTransposingClef>` —
        // previously we'd fall back to G clef.
        let defaultClef = node.first("defaultClef")?.text
            ?? node.first("defaultTransposingClef")?.text
            ?? node.first("defaultConcertClef")?.text
        let mscxID = node.attributes["id"]

        // Per spec: walk every <bracket> child in document order so
        // column ordering is preserved. Unknown / malformed values
        // are silently dropped (parser's permissive policy).
        var brackets: [BracketItem] = []
        for el in node.all("bracket") {
            guard let typeStr = el.attributes["type"],
                  let typeRaw = Int(typeStr),
                  let bracketType = BracketType(rawValue: typeRaw)
            else { continue }
            guard let spanStr = el.attributes["span"],
                  let span = Int(spanStr)
            else { continue }
            let column = el.attributes["col"].flatMap(Int.init) ?? 0
            let visible = (el.attributes["visible"] ?? "1") != "0"
            brackets.append(BracketItem(
                type: bracketType,
                span: span,
                column: column,
                visible: visible,
            ))
        }

        return (mscxID, Staff(
            staffType: staffType,
            group: group,
            defaultClefType: defaultClef,
            brackets: brackets,
            measures: [],
        ))
    }
}

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
}

extension MSCXTopLevelStaff {
    static func decode(_ node: XMLTreeNode) throws -> MSCXTopLevelStaff {
        guard let id = node.attributes["id"] else {
            throw SheetMusicError.malformedScore(
                reason: "top-level <Staff> missing id attribute",
            )
        }
        let measureNodes = node.all("Measure")
            .filter { !Measure.isMultiMeasureRestContainer($0) }
        var measures: [Measure] = []
        var systemElementsByMeasure: [[PositionedSystemElement]] = []
        for measureNode in measureNodes {
            let result = try Measure.decode(measureNode)
            measures.append(result.measure)
            systemElementsByMeasure.append(result.systemElements)
        }
        return MSCXTopLevelStaff(
            mscxID: id,
            measures: measures,
            systemElementsByMeasure: systemElementsByMeasure,
        )
    }
}

/// Pairs declared (per-Part) staves with top-level (measures) staves.
/// Hybrid rule:
///   1. Declarations with an explicit id consume the matching top-level Staff.
///   2. Declarations without an id consume the next remaining top-level Staff
///      in document order.
///   3. Any top-level Staff left unconsumed is a malformed-score error.
struct MSCXStaffPairing {
    var partID: String
    var trackName: String?
    var instrument: Instrument
    var declared: [(mscxID: String?, staff: Staff)]
}

/// Result of part assembly: the wired-up `[Part]` plus the
/// score-level `[SystemMeasure]` aggregating system elements from
/// every staff into a single array indexed by measure number.
struct MSCXAssembledParts {
    var parts: [Part]
    var systemMeasures: [SystemMeasure]
}

func assembleParts( // swiftlint:disable:this function_body_length
    decoded: [MSCXStaffPairing],
    topLevel: [MSCXTopLevelStaff],
) throws -> MSCXAssembledParts {
    var byID: [String: MSCXTopLevelStaff] = [:]
    var orderedIDs: [String] = []
    for tl in topLevel {
        byID[tl.mscxID] = tl
        orderedIDs.append(tl.mscxID)
    }
    var consumed: Set<String> = []
    var unconsumedQueue = orderedIDs

    // Per-staff per-measure system elements, paired with the
    // resolved StaffAddress, so we can merge across staves into
    // score.systemMeasures after part assembly is complete.
    var perStaffSystemElements: [(address: StaffAddress, perMeasure: [[PositionedSystemElement]])] = []

    var parts: [Part] = []
    for dp in decoded {
        var assembled: [Staff] = []
        for (staffIndexInPart, declared) in dp.declared.enumerated() {
            let topLevelStaff: MSCXTopLevelStaff
            if let id = declared.mscxID {
                guard let tl = byID[id] else {
                    throw SheetMusicError.malformedScore(
                        reason:
                        "Part '\(dp.partID)' declares <Staff id=\"\(id)\">"
                            + " but no top-level <Staff> with that id was found",
                    )
                }
                topLevelStaff = tl
                consumed.insert(id)
                unconsumedQueue.removeAll { $0 == id }
            } else {
                // Pop next unconsumed top-level Staff in document order.
                while let head = unconsumedQueue.first, consumed.contains(head) {
                    unconsumedQueue.removeFirst()
                }
                guard let head = unconsumedQueue.first,
                      let tl = byID[head]
                else {
                    throw SheetMusicError.malformedScore(
                        reason:
                        "Part '\(dp.partID)' has an id-less <Staff> declaration"
                            + " but no remaining top-level <Staff> to consume",
                    )
                }
                topLevelStaff = tl
                consumed.insert(head)
                unconsumedQueue.removeFirst()
            }
            var s = declared.staff
            s.measures = topLevelStaff.measures
            assembled.append(s)
            let address = StaffAddress(
                partIndex: parts.count,
                staffIndexInPart: staffIndexInPart,
            )
            perStaffSystemElements.append(
                (address, topLevelStaff.systemElementsByMeasure),
            )
        }
        parts.append(Part(
            id: dp.partID,
            trackName: dp.trackName,
            instrument: dp.instrument,
            staves: assembled,
        ))
    }

    let leftover = orderedIDs.filter { !consumed.contains($0) }
    if !leftover.isEmpty {
        throw SheetMusicError.malformedScore(
            reason:
            "top-level <Staff id=\"\(leftover.joined(separator: ","))\"> not claimed by any Part",
        )
    }

    let measureCount = perStaffSystemElements
        .map { $0.perMeasure.count }
        .max() ?? 0
    var systemMeasures = Array(
        repeating: SystemMeasure(),
        count: measureCount,
    )
    for entry in perStaffSystemElements {
        for (measureIndex, elements) in entry.perMeasure.enumerated() {
            guard measureIndex < systemMeasures.count else { continue }
            for var element in elements {
                element.originalStaff = entry.address
                systemMeasures[measureIndex].elements.append(element)
            }
        }
    }
    // Stable sort each measure's elements by `MeasurePosition` so
    // downstream consumers can walk them in time order without
    // needing to re-sort. Elements from different staves at the
    // same position keep their relative insertion order
    // (top-down staff iteration above).
    for index in systemMeasures.indices {
        systemMeasures[index].elements.sort {
            $0.position < $1.position
        }
    }
    return MSCXAssembledParts(parts: parts, systemMeasures: systemMeasures)
}
