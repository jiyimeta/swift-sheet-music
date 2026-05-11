import Foundation
import SheetMusicCore

extension MidiImporter {
    // MARK: - Clef inference

    /// Pick the clef whose middle staff line is closest (in
    /// summed-absolute MIDI distance) to the track's note-on pitches.
    /// Drum tracks are handled separately at the call site and never
    /// reach here — this path is for pitched tracks only.
    ///
    /// - Parameters:
    ///   - events: raw `TimedMidiEvent`s of one pitched track. Only
    ///     note-on events with non-zero velocity contribute.
    ///   - candidates: clefs the caller will accept. Ties break
    ///     toward earlier entries.
    /// - Returns: the chosen clef, or `.treble` if `candidates` is
    ///   empty.
    static func inferClef(
        events: [TimedMidiEvent],
        candidates: [NotatedClef],
    ) -> NotatedClef {
        var pitches: [Int] = []
        for ev in events {
            if case let .noteOn(_, p, v) = ev.event, v > 0 {
                pitches.append(p)
            }
        }
        return inferClef(pitches: pitches, candidates: candidates)
    }

    /// Pitch-only entry point. Exposed separately for unit testing —
    /// callers that already have a pitch list don't need to wrap it in
    /// `TimedMidiEvent`s.
    static func inferClef(
        pitches: [Int],
        candidates: [NotatedClef],
    ) -> NotatedClef {
        guard let first = candidates.first else { return .treble }
        guard !pitches.isEmpty else { return first }
        var bestClef = first
        var bestCost = pitches.reduce(0) { $0 + abs($1 - midLineMIDIPitch(first)) }
        for c in candidates.dropFirst() {
            let cost = pitches.reduce(0) { $0 + abs($1 - midLineMIDIPitch(c)) }
            if cost < bestCost {
                bestCost = cost
                bestClef = c
            }
        }
        return bestClef
    }

    /// MIDI pitch of the note sitting on the middle staff line for a
    /// given clef. Mirrors the `midLineDiatonic` table in
    /// `SheetMusicLayout/PitchStaffPosition.swift` — duplicated here
    /// because `SheetMusicMIDI` does not depend on `Layout`.
    private static func midLineMIDIPitch(_ clef: NotatedClef) -> Int {
        switch clef {
        case .treble: 71 // B4
        case .treble8va: 83 // B5
        case .treble8vb: 59 // B3
        case .treble15ma: 95 // B6
        case .treble15mb: 47 // B2
        case .bass: 50 // D3
        case .bass8va: 62 // D4
        case .bass8vb: 38 // D2
        case .soprano: 67 // G4
        case .alto: 60 // C4
        case .tenor: 57 // A3
        case .baritone: 53 // F3
        case .percussion: 71 // unpitched — fallback, not used for inference
        case .percussion2: 71
        }
    }
}
