import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Active swing setting threaded through voice rendering. Mirrors
    /// MuseScore's per-staff `SwingParameters` (types.h:1293).
    /// `unitTicks == 0` disables swing regardless of `ratio`.
    struct SwingState: Equatable {
        var unitTicks: Int
        var ratio: Int

        var isOn: Bool {
            unitTicks > 0
        }

        static let off = SwingState(unitTicks: 0, ratio: 60)

        init(unitTicks: Int, ratio: Int) {
            self.unitTicks = unitTicks
            self.ratio = ratio
        }

        /// Build the initial swing state from a score-level Style block.
        /// MuseScore's `Staff::swing(tick=0)` (staff.cpp:1006) reads
        /// the same fields when no in-piece directive applies yet.
        init(style: ScoreStyle, division: Int) {
            switch style.swingUnit {
            case .off: unitTicks = 0
            case .eighth: unitTicks = division / 2
            case .sixteenth: unitTicks = division / 4
            }
            ratio = style.swingRatio
        }
    }

    /// Per-staff sorted lookup of `(tick, SwingState)` entries.
    /// Mirrors MuseScore's `Staff::m_swingList` (staff.h:312); each
    /// staff carries its own list, populated by `Score::updateSwing`
    /// (score.cpp:6081). `initial` is the score-level Style swing,
    /// returned when `tick` precedes every entry.
    struct SwingMap: Equatable {
        let entries: [Entry]
        let initial: SwingState

        struct Entry: Equatable {
            let tick: Int
            let state: SwingState
        }

        static let empty = SwingMap(entries: [], initial: .off)

        /// Active swing state at `tick`. Mirrors `Staff::swing(tick)`
        /// (staff.cpp:1022) — `upper_bound` on the tick map, returning
        /// the entry one before the boundary.
        func state(atTick tick: Int) -> SwingState {
            var lo = 0, hi = entries.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if entries[mid].tick <= tick {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            return lo == 0 ? initial : entries[lo - 1].state
        }
    }

    /// Build a `SwingMap` per staff in `score.allStaves` order.
    /// Reads `Score.systemMeasures` and assigns each swing directive
    /// to staff maps based on `Swing.isSystemText`: system swing
    /// fans out to every staff (matches the
    /// `if (st->systemFlag())` branch of `Score::updateSwing`,
    /// score.cpp:6106); staff swing goes only to its
    /// `originalStaff` (which falls back to the canonical staff
    /// (0,0) when `nil`).
    static func collectSwingMaps(
        score: Score, division: Int,
    ) -> [SwingMap] {
        let initial = SwingState(style: score.style, division: division)
        let allStaves = score.allStaves
        let staffCount = allStaves.count
        guard staffCount > 0 else { return [] }
        var perStaff: [[SwingMap.Entry]] = Array(
            repeating: [], count: staffCount,
        )
        // Reference measure tick budgets — staves share the same
        // time signature so any non-empty part/staff serves as the
        // tick-base provider.
        let referenceMeasures = allStaves.first?.staff.measures ?? []
        var measureBases: [Int] = []
        let measureDurations = referenceMeasures.effectiveMeasureDurations()
        do {
            var acc = 0
            for (i, m) in referenceMeasures.enumerated() {
                measureBases.append(acc)
                let mDur = i < measureDurations.count
                    ? measureDurations[i]
                    : Fraction(numerator: 4, denominator: 4)
                acc += measureTicks(
                    measure: m, division: division,
                    measureDuration: mDur,
                )
            }
        }
        var addressToStaffIdx: [StaffAddress: Int] = [:]
        for (i, entry) in allStaves.enumerated() {
            addressToStaffIdx[entry.address] = i
        }
        let canonical = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        for (measureIndex, systemMeasure) in score.systemMeasures.enumerated() {
            guard measureIndex < measureBases.count else { continue }
            let measureBase = measureBases[measureIndex]
            for positioned in systemMeasure.elements {
                guard case let .swing(s) = positioned.element else { continue }
                let tick = measureBase + positioned.position.ticks(division: division)
                let state = SwingState(
                    unitTicks: s.swingUnitTicks(division: division),
                    ratio: s.ratio,
                )
                let mapEntry = SwingMap.Entry(tick: tick, state: state)
                if s.isSystemText {
                    for i in 0 ..< staffCount {
                        perStaff[i].append(mapEntry)
                    }
                } else {
                    let address = positioned.originalStaff ?? canonical
                    if let idx = addressToStaffIdx[address] {
                        perStaff[idx].append(mapEntry)
                    }
                }
            }
        }
        return perStaff.map { entries in
            SwingMap(
                entries: entries.sorted { $0.tick < $1.tick },
                initial: initial,
            )
        }
    }

    /// Result of applying swing to one chord. Both deltas are in
    /// ticks; positive `onsetShift` pushes the note-on later, positive
    /// `lengthDelta` extends the chord's sounding duration.
    struct SwingAdjustment: Equatable {
        var onsetShift: Int
        var lengthDelta: Int

        static let none = SwingAdjustment(onsetShift: 0, lengthDelta: 0)
    }

    /// Compute the swing adjustment for a chord at `startTick` whose
    /// nominal duration is `chordTicks`. Mirrors
    /// `Swing::swingAdjustParams` (engraving/dom/swing.cpp), translated
    /// from the C++ per-mille (`onTime`, `gateTime`) representation
    /// into absolute tick deltas.
    ///
    /// Skip rules (matching MuseScore):
    ///   - swing off (`unitTicks == 0`)
    ///   - chord sits inside a tuplet (`!chord->tuplet()`)
    ///   - chord or its predecessor shorter than the swing unit
    ///     ("subdivided" — `isSubdivided`); upbeat shift only
    ///   - next chord shorter than swing unit; downbeat extension only
    ///
    /// The score's first chord is treated as having no predecessor,
    /// so its leading downbeat never sees a "previous shorter" bias.
    static func swingAdjustment(
        startTick: Int,
        chordTicks: Int,
        prevChordTicks: Int?,
        nextChordTicks: Int?,
        isInTuplet: Bool,
        state: SwingState,
    ) -> SwingAdjustment {
        guard state.isOn, !isInTuplet else { return .none }
        let swingBeat = state.unitTicks * 2
        // (ratio - 50) * swingBeat / 100 — at ratio 50 this is zero
        // (straight); at ratio 60 the down-beat steals 1/10 of the
        // pair length from the up-beat.
        let swingTickAdjust = swingBeat * (state.ratio - 50) / 100
        var onsetShift = 0
        var lengthDelta = 0
        // Up-beat in pair: shift forward unless either this chord or
        // the previous one is finer than the swing unit.
        if startTick % swingBeat == state.unitTicks {
            let subdivided = chordTicks < state.unitTicks
                || (prevChordTicks.map { $0 < state.unitTicks } ?? false)
            if !subdivided {
                onsetShift += swingTickAdjust
                lengthDelta -= swingTickAdjust
            }
        }
        // Down-beat extending across the pair midpoint: lengthen
        // unless the next chord is itself a sub-division (which would
        // need to start at its own un-shifted position).
        let endTick = startTick + chordTicks
        if endTick % swingBeat == state.unitTicks {
            let nextSubdivided = nextChordTicks
                .map { $0 < state.unitTicks } ?? false
            if !nextSubdivided {
                lengthDelta += swingTickAdjust
            }
        }
        return SwingAdjustment(
            onsetShift: onsetShift,
            lengthDelta: lengthDelta,
        )
    }

    /// Find the played tick count of the chord immediately before
    /// `index` in `elements`. Walks backwards skipping non-chord
    /// VoiceElements (clefs, tempo, etc.). Returns nil when no chord
    /// precedes — the score's leading downbeat case.
    ///
    /// `measureDuration` is forwarded to `resolved(in:)` so any
    /// `.measure` rest in the adjacent element converts to the correct
    /// concrete fraction before the tick count is taken.
    static func previousChordTicks(
        in elements: [VoiceElement],
        before index: Int,
        measureDuration: Fraction,
        division: Int,
    ) -> Int? {
        guard index > 0 else { return nil }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if case let .chord(chord) = elements[i] {
                return chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            }
        }
        return nil
    }

    /// Find the played tick count of the chord immediately after
    /// `index`. Mirror of `previousChordTicks`. Used by the down-beat
    /// extension branch.
    ///
    /// `measureDuration` is forwarded to `resolved(in:)` so any
    /// `.measure` rest in the adjacent element converts to the correct
    /// concrete fraction before the tick count is taken.
    static func nextChordTicks(
        in elements: [VoiceElement],
        after index: Int,
        measureDuration: Fraction,
        division: Int,
    ) -> Int? {
        guard index + 1 < elements.count else { return nil }
        for i in (index + 1) ..< elements.count {
            if case let .chord(chord) = elements[i] {
                return chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            }
        }
        return nil
    }

    /// True when `index` falls inside any of `tuplets`. Used to skip
    /// swing on tuplet members (matches MuseScore's `!chord->tuplet()`
    /// check in compatmidirender.cpp:172).
    static func isChordInTuplet(
        elementIndex index: Int,
        voiceTuplets tuplets: [Tuplet],
    ) -> Bool {
        tuplets.contains { $0.startIndex <= index && index <= $0.endIndex }
    }
}
