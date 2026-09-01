import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Resolve one staff slot's system-initial clefs into a single coherent
    /// sequence.
    ///
    /// A part's clef is ONE fact, re-engraved at the left edge of every
    /// system. The raster front-end reads each system independently, so a
    /// clef the detector is merely unsure about costs that system's staff a
    /// whole octave — and no detection threshold fixes it in both
    /// directions. Measured on the `.mscz` corpus, both failure modes are
    /// this same defect seen from opposite sides:
    ///
    ///   threshold too high  a true `clefF8va` splits its confidence with
    ///                       plain `clefF` and NEITHER clears τ, so the staff
    ///                       reads as the treble default;
    ///   threshold too low   a spurious plain clef outranks the true octave
    ///                       one in a single system.
    ///
    /// Reading the systems as a sequence rather than independently answers
    /// both, because a clef is either constant or changes in RUNS:
    ///
    /// - when every system that read anything agrees, that clef is the
    ///   slot's clef and fills the systems that read nothing. One confident
    ///   system is enough to carry the rest — which is the point, since
    ///   lowering τ far enough to catch every system costs more elsewhere
    ///   than it recovers;
    /// - otherwise the readings disagree, which a genuine mid-score clef
    ///   change also does, so only an ISOLATED reading — one whose two
    ///   neighbours agree with each other and not with it — is overruled. At
    ///   a real change the neighbours disagree, and nothing is rewritten.
    ///
    /// A slot nobody read a clef for is left alone: silence is not evidence
    /// for a clef, and the caller's running default stays in charge. So is a
    /// one-system document, which has no second opinion to offer.
    ///
    /// `nil` means "this system read no clef". The result is the same length
    /// as the input.
    static func consensusInitialClefs(perSystem readings: [Clef?]) -> [Clef?] {
        let read = readings.compactMap(\.self)
        guard let first = read.first else { return readings }
        if Set(read.map(\.concertClefType)).count == 1 {
            return readings.map { _ in first }
        }
        var out = readings
        for index in readings.indices {
            guard index > 0, index + 1 < readings.count,
                  let before = readings[index - 1],
                  let after = readings[index + 1],
                  before.concertClefType == after.concertClefType,
                  readings[index]?.concertClefType != before.concertClefType
            else { continue }
            out[index] = before
        }
        return out
    }

    /// Per staff SLOT, the system-initial clef each system should be read
    /// under, once the slot's systems are resolved against each other by
    /// `consensusInitialClefs`.
    ///
    /// Keyed slot → system index. Only entries that CHANGE a system's own
    /// reading are returned, so a document the consensus has nothing to say
    /// about (every slot already consistent, or a single system) produces an
    /// empty map and leaves the assembly path untouched.
    ///
    /// Mirrors `resolveF8vaSlots`' slot routing (`partSlotMapping` +
    /// `shape.slotsByPartIndex`) so the aggregation lands in the slots the
    /// measures will. A slot absent from some system — an under-full system
    /// missing a part — simply contributes no reading for it, and the
    /// remaining systems still form the sequence.
    static func resolveInitialClefConsensus(
        systems: [ImportSystem], shape: PartShape,
    ) -> [Int: [Int: Clef]] {
        var readingsBySlot: [Int: [(system: Int, clef: Clef?)]] = [:]
        for (sysIndex, system) in systems.enumerated() {
            let refForSystemPart = partSlotMapping(system: system, shape: shape)
            for (partIdx, importPart) in system.parts.enumerated() {
                let refIdx = refForSystemPart[partIdx]
                guard let slots = shape.slotsByPartIndex[refIdx] else { continue }
                for (slot, importStaff) in zip(slots, importPart.staves) {
                    readingsBySlot[slot, default: []]
                        .append((sysIndex, staffInitialClef(importStaff)))
                }
            }
        }
        var overrides: [Int: [Int: Clef]] = [:]
        for (slot, entries) in readingsBySlot {
            let resolved = consensusInitialClefs(perSystem: entries.map(\.clef))
            for (entry, decided) in zip(entries, resolved) {
                guard let decided,
                      decided.concertClefType != entry.clef?.concertClefType
                else { continue }
                overrides[slot, default: [:]][entry.system] = decided
            }
        }
        return overrides
    }

    /// Rewrite a staff-in-system's measure-0 clef to the consensus decision,
    /// inserting one when the system read none. Everything after measure 0 —
    /// a genuine mid-score clef change — is left exactly as read.
    static func applyInitialClefConsensus(
        _ events: [ScoreStateEvent], to decided: Clef?,
    ) -> [ScoreStateEvent] {
        guard let decided else { return events }
        var out = events.filter { event in
            if case let .clefChange(_, measureIndex) = event { return measureIndex != 0 }
            return true
        }
        out.insert(.clefChange(decided, atMeasureIndex: 0), at: 0)
        return out
    }
}
