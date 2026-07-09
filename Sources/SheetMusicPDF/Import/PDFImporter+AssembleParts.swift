import CoreGraphics
import Foundation
import SheetMusicCore

// Part-shape derivation and per-system part → global-slot mapping for the
// assembler. Split out of PDFImporter+Assemble.swift to keep both files
// under the 400-line cap. `PartShape` is module-internal (not fileprivate)
// so PDFImporter+Assemble.swift can use it.

extension PDFImporter {
    // MARK: - Part shape

    /// Map of `referenceSystem.parts[i]` → flat staff-slot indices, plus
    /// the assembled `Part` list with placeholder instruments.
    struct PartShape {
        var parts: [Part]
        var slotsByPartIndex: [Int: [Int]]
        var totalStaffSlots: Int
    }

    /// Total staff count across all parts in a system.
    static func totalStaves(_ system: ImportSystem) -> Int {
        system.parts.reduce(0) { $0 + $1.staves.count }
    }

    /// Median staff line-spacing (one spatium) across a system's staves,
    /// used as the row-grouping tolerance for `removeColonAnnotations`.
    /// Falls back to a nominal value when the system has no measurable staff.
    static func referenceLineSpacing(_ system: ImportSystem) -> CGFloat {
        let spacings = system.parts
            .flatMap(\.staves)
            .compactMap { staff -> CGFloat? in
                guard let lo = staff.staff.yLines.first,
                      let hi = staff.staff.yLines.last, hi > lo
                else { return nil }
                return (hi - lo) / 4
            }
            .sorted()
        guard !spacings.isEmpty else { return 8 }
        return spacings[spacings.count / 2]
    }

    static func partShape(from referenceSystem: ImportSystem) -> PartShape {
        var parts: [Part] = []
        var slotsByPartIndex: [Int: [Int]] = [:]
        var nextSlot = 0
        for (partIdx, partProto) in referenceSystem.parts.enumerated() {
            let staffCount = partProto.staves.count
            let part = Part(
                id: "P\(partIdx + 1)",
                trackName: nil,
                instrument: Instrument(id: "voice"),
                staves: Array(
                    repeating: SheetMusicCore.Staff(staffType: "stdNormal", group: "pitched"),
                    count: staffCount,
                ),
            )
            parts.append(part)
            var slots: [Int] = []
            for _ in 0 ..< staffCount {
                slots.append(nextSlot)
                nextSlot += 1
            }
            slotsByPartIndex[partIdx] = slots
        }
        return PartShape(
            parts: parts,
            slotsByPartIndex: slotsByPartIndex,
            totalStaffSlots: nextSlot,
        )
    }

    // MARK: - Part → global-slot mapping

    /// For each `system.parts` index, the reference part index whose global
    /// slots it should fill.
    ///
    /// - **Full system** (part count == reference part count): the identity
    ///   map (`i → i`) — the overwhelmingly common case (the curated corpus
    ///   only produces full systems, so this branch is a pure no-op there).
    /// - **Under-full system** (fewer parts than the reference — MuseScore's
    ///   hide-empty-staves omitted a resting part's staff for this system):
    ///   the identity PREFIX (`i → i`). Hide-empty-staves never reorders the
    ///   surviving staves, so a system's parts are an order-preserving SUBSET
    ///   of the global part list; but WHICH parts are hidden is not
    ///   recoverable from geometry, because the survivors are re-justified
    ///   over the page — their normalized vertical positions carry no slot
    ///   information. (A previous nearest-normalized-y matching here actively
    ///   misrouted bottom parts whenever the reference carried an extra
    ///   bottom staff — e.g. a percussion staff detected on a single page —
    ///   because re-justification always pins the system's bottom part to the
    ///   reference's bottom slot.) In this corpus the hidden staves are
    ///   overwhelmingly the BOTTOM slots (percussion / aux parts under the
    ///   vocals), so the top-aligned prefix is the best order-preserving
    ///   assignment; refining the subset choice by per-slot clef/key
    ///   continuity is the planned next step for the remaining cases.
    static func partSlotMapping(
        system: ImportSystem, shape: PartShape,
    ) -> [Int] {
        _ = shape // subset choice by clef/key continuity: planned follow-up
        return Array(0 ..< system.parts.count)
    }

    // MARK: - F8va clef resolution (pre-pass)

    /// For every staff SLOT whose content reads under an ambiguous E065
    /// (F8va) clef, decide F8va-vs-plain-F ONCE from the slot's whole-part
    /// note population (aggregated across every system the slot appears in),
    /// and return only the slots that should be DOWNGRADED to plain F.
    ///
    /// Mirrors `appendSystem`'s slot routing (`partSlotMapping` +
    /// `shape.slotsByPartIndex`) so the aggregation lands in the same slots
    /// the measures will. Returns an empty map when no slot uses F8va — the
    /// common case, leaving the assembly path untouched.
    static func resolveF8vaSlots(
        systems: [ImportSystem], shape: PartShape,
    ) -> [Int: Clef] {
        var pitchesBySlot: [Int: [Int]] = [:]
        for system in systems {
            let refForSystemPart = partSlotMapping(system: system, shape: shape)
            for (partIdx, importPart) in system.parts.enumerated() {
                let refIdx = refForSystemPart[partIdx]
                guard let slots = shape.slotsByPartIndex[refIdx] else { continue }
                for (slot, importStaff) in zip(slots, importPart.staves) {
                    guard staffInitialClefIsF8va(importStaff) else { continue }
                    pitchesBySlot[slot, default: []]
                        .append(contentsOf: f8vaCandidatePitches(staff: importStaff))
                }
            }
        }
        var overrides: [Int: Clef] = [:]
        for (slot, pitches) in pitchesBySlot {
            let resolved = disambiguateF8vaClef(
                Clef(concertClefType: "F8va"), f8vaPitches: pitches,
            )
            if resolved.concertClefType != "F8va" {
                overrides[slot] = resolved
            }
        }
        return overrides
    }
}
