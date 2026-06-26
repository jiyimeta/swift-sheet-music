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
    /// the assembled `Part` list with placeholder instruments and each
    /// reference part's normalized top→bottom vertical position (used by
    /// `appendSystem` to place an UNDER-FULL system's parts in the correct
    /// global slots rather than always starting from part 0).
    struct PartShape {
        var parts: [Part]
        var slotsByPartIndex: [Int: [Int]]
        var totalStaffSlots: Int
        /// Normalized vertical position (0 = page top, 1 = page bottom) of
        /// each reference part, indexed by reference part index. Empty when
        /// the reference system has < 2 parts (no spread to normalize).
        var refNormY: [Double]
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

    /// Representative y of an import part: the top staff-line of its top
    /// staff (largest y in PDF y-up coords). Parts are emitted top→bottom,
    /// so this decreases with part index.
    private static func partTopY(_ part: ImportPart) -> CGFloat {
        part.staves.first?.staff.yLines.last ?? 0
    }

    /// Normalized top→bottom positions (0 = top, 1 = bottom) of a system's
    /// parts, from their representative y. Empty when there's no vertical
    /// spread (≤ 1 part or all parts at the same y).
    private static func normalizedPartYs(_ parts: [ImportPart]) -> [Double] {
        let ys = parts.map { partTopY($0) }
        guard let hi = ys.max(), let lo = ys.min(), hi > lo else { return [] }
        let span = Double(hi - lo)
        return ys.map { 1.0 - Double($0 - lo) / span }
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
            refNormY: normalizedPartYs(referenceSystem.parts),
        )
    }

    // MARK: - Part → global-slot mapping

    /// For each `system.parts` index, the reference part index whose global
    /// slots it should fill.
    ///
    /// - **Full system** (part count == reference part count): the identity
    ///   map (`i → i`). This is the overwhelmingly common case and the only
    ///   one exercised by the current corpus once F3 makes every system full,
    ///   so the mapping must be a pure no-op there — no behavior change.
    /// - **Under-full system** (fewer parts than the reference, e.g. a medley
    ///   page where some instruments rest for a system): match each present
    ///   part to the reference part nearest in normalized vertical position,
    ///   assigned monotonically (top→bottom, no reuse) so order is preserved
    ///   and a missing instrument leaves its slots empty instead of starving
    ///   the bottom part. Falls back to the identity prefix when there's no
    ///   usable vertical spread (degenerate geometry).
    static func partSlotMapping(
        system: ImportSystem, shape: PartShape,
    ) -> [Int] {
        let sysCount = system.parts.count
        let refCount = shape.parts.count
        // Identity for full (or over-full) systems — the no-op fast path.
        if sysCount >= refCount {
            return Array(0 ..< sysCount)
        }
        let sysNormY = normalizedPartYs(system.parts)
        let refNormY = shape.refNormY
        // No usable vertical spread on either side → keep the historical
        // top-aligned behavior (identity prefix).
        guard sysNormY.count == sysCount, refNormY.count == refCount else {
            return Array(0 ..< sysCount)
        }
        // Greedy monotonic nearest-position assignment: walk system parts
        // top→bottom, each taking the nearest still-available reference part
        // at or after the previous pick.
        var mapping: [Int] = []
        var nextRef = 0
        for sysIdx in 0 ..< sysCount {
            let target = sysNormY[sysIdx]
            // Reference parts still available: nextRef ..< refCount, but leave
            // room for the remaining system parts after this one.
            let remainingSys = sysCount - sysIdx - 1
            let maxRef = refCount - 1 - remainingSys
            var best = nextRef
            var bestDist = Double.greatestFiniteMagnitude
            for r in nextRef ... max(nextRef, maxRef) where r < refCount {
                let d = abs(refNormY[r] - target)
                if d < bestDist {
                    bestDist = d
                    best = r
                }
            }
            mapping.append(best)
            nextRef = best + 1
        }
        return mapping
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
