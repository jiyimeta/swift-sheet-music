import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Decodes the `<StaffType>` / `<defaultClef>` portion of an
    /// inside-`<Part><Staff>` element. Measures are added separately
    /// during pairing — see `assembleParts(decoded:topLevel:)`.
    static func declared(_ node: XMLTreeNode) -> (mscxID: String?, staff: Staff) {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        let defaultClef = node.first("defaultClef")?.text
        let mscxID = node.attributes["id"]
        return (mscxID, Staff(
            staffType: staffType,
            group: group,
            defaultClefType: defaultClef,
            measures: []
        ))
    }
}

/// Top-level `<Staff id="N">` measure block — id is required at this
/// level; raised in `decode` if missing.
struct MSCXTopLevelStaff {
    let mscxID: String
    let measures: [Measure]
}

extension MSCXTopLevelStaff {
    static func decode(_ node: XMLTreeNode) throws -> MSCXTopLevelStaff {
        guard let id = node.attributes["id"] else {
            throw SheetMusicError.malformedScore(
                reason: "top-level <Staff> missing id attribute"
            )
        }
        let measures = try node.all("Measure").map { try Measure.decode($0) }
        return MSCXTopLevelStaff(mscxID: id, measures: measures)
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

func assembleParts(
    decoded: [MSCXStaffPairing],
    topLevel: [MSCXTopLevelStaff]
) throws -> [Part] {
    var byID: [String: [Measure]] = [:]
    var orderedIDs: [String] = []
    for tl in topLevel {
        byID[tl.mscxID] = tl.measures
        orderedIDs.append(tl.mscxID)
    }
    var consumed: Set<String> = []
    var unconsumedQueue = orderedIDs

    var parts: [Part] = []
    for dp in decoded {
        var assembled: [Staff] = []
        for declared in dp.declared {
            let measures: [Measure]
            if let id = declared.mscxID {
                guard let m = byID[id] else {
                    throw SheetMusicError.malformedScore(reason:
                        "Part '\(dp.partID)' declares <Staff id=\"\(id)\">"
                            + " but no top-level <Staff> with that id was found"
                    )
                }
                measures = m
                consumed.insert(id)
                unconsumedQueue.removeAll { $0 == id }
            } else {
                // Pop next unconsumed top-level Staff in document order.
                while let head = unconsumedQueue.first, consumed.contains(head) {
                    unconsumedQueue.removeFirst()
                }
                guard let head = unconsumedQueue.first,
                      let m = byID[head]
                else {
                    throw SheetMusicError.malformedScore(reason:
                        "Part '\(dp.partID)' has an id-less <Staff> declaration"
                            + " but no remaining top-level <Staff> to consume"
                    )
                }
                measures = m
                consumed.insert(head)
                unconsumedQueue.removeFirst()
            }
            var s = declared.staff
            s.measures = measures
            assembled.append(s)
        }
        parts.append(Part(
            id: dp.partID,
            trackName: dp.trackName,
            instrument: dp.instrument,
            staves: assembled
        ))
    }

    let leftover = orderedIDs.filter { !consumed.contains($0) }
    if !leftover.isEmpty {
        throw SheetMusicError.malformedScore(reason:
            "top-level <Staff id=\"\(leftover.joined(separator: ","))\"> not claimed by any Part"
        )
    }
    return parts
}
