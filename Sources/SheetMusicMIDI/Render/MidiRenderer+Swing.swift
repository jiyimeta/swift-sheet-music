import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Active swing setting threaded through voice rendering. Mirrors
    /// MuseScore's per-staff `SwingParameters` (types.h:1293).
    /// `unitTicks == 0` disables swing regardless of `ratio`.
    struct SwingState: Equatable {
        var unitTicks: Int
        var ratio: Int

        var isOn: Bool { unitTicks > 0 }

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
        state: SwingState
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
            lengthDelta: lengthDelta
        )
    }

    /// Find the played tick count of the chord immediately before
    /// `index` in `elements`. Walks backwards skipping non-chord
    /// VoiceElements (clefs, tempo, etc.). Returns nil when no chord
    /// precedes — the score's leading downbeat case.
    static func previousChordTicks(
        in elements: [VoiceElement],
        before index: Int,
        division: Int
    ) -> Int? {
        guard index > 0 else { return nil }
        for i in stride(from: index - 1, through: 0, by: -1) {
            if case let .chord(chord) = elements[i] {
                return chord.duration.ticks(division: division)
            }
        }
        return nil
    }

    /// Find the played tick count of the chord immediately after
    /// `index`. Mirror of `previousChordTicks`. Used by the down-beat
    /// extension branch.
    static func nextChordTicks(
        in elements: [VoiceElement],
        after index: Int,
        division: Int
    ) -> Int? {
        guard index + 1 < elements.count else { return nil }
        for i in (index + 1) ..< elements.count {
            if case let .chord(chord) = elements[i] {
                return chord.duration.ticks(division: division)
            }
        }
        return nil
    }

    /// True when `index` falls inside any of `tuplets`. Used to skip
    /// swing on tuplet members (matches MuseScore's `!chord->tuplet()`
    /// check in compatmidirender.cpp:172).
    static func isChordInTuplet(
        elementIndex index: Int,
        voiceTuplets tuplets: [Tuplet]
    ) -> Bool {
        tuplets.contains { $0.startIndex <= index && index <= $0.endIndex }
    }
}
