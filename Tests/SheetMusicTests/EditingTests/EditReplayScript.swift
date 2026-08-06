import Foundation
@testable import SheetMusicCore

/// One step of a scripted editing session.
enum EditReplayStep {
    case intent(EditIntent)
    case undo
    case redo
}

/// A fixed, hand-rolled sequence of edits used to prove that two sessions fed the same steps agree at every step.
///
/// Everything here is derived from the step index — no randomness, no clock. A determinism test that is itself
/// nondeterministic proves nothing, and the same script has to be reproducible on a device months later.
enum EditReplayScript {
    /// 100 steps over `midi01.mscx`'s only measure: write, retime, delete, and periodically undo/redo. Steps that
    /// the engine refuses (a slot that a previous delete has not yet turned into a rest, say) are part of the point
    /// — a refusal must be refused identically on both sides.
    ///
    /// `midi01.mscx` (`Tests/SheetMusicTests/Resources/midi01.mscx`, shared with the device-side replay in SP0
    /// Task 10) has exactly one measure of six voice elements: `KeySig`, `TimeSig`, then four quarter-note chords
    /// (pitches 60-63) at element indices 2 through 5. There is no rest anywhere in the fixture as written, and no
    /// measure past index 0 — so this script pins `measureIndex` to 0 and cycles `elementIndex` over 2...5, the
    /// only slots that are ever chords. `.inputNote` only succeeds once a prior `.delete` at that same slot has
    /// turned its chord into a rest (see `DeleteVoiceElement`), which is exactly the kind of history-dependent
    /// refusal-then-acceptance the replay is meant to exercise.
    static func standard(staff: StaffAddress) -> [EditReplayStep] {
        let durations: [NoteDuration] = [.quarter, .eighth, .half, .sixteenth]
        var steps: [EditReplayStep] = []
        for index in 0 ..< 100 {
            let measureIndex = 0
            let elementIndex = 2 + (index % 4)
            let slot = VoiceElementID(
                staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: elementIndex,
            )
            let rest = RestID(
                staff: staff, measureIndex: measureIndex, voiceIndex: 0, elementIndex: elementIndex,
            )
            switch index % 7 {
            case 0, 1, 2:
                steps.append(.intent(.inputNote(
                    at: rest,
                    pitch: 60 + (index % 12),
                    tpc: 14,
                    duration: durations[index % durations.count],
                )))
            case 3:
                steps.append(.intent(.setChordDuration(at: slot, duration: durations[(index + 1) % durations.count])))
            case 4:
                steps.append(.intent(.composite([
                    .delete(at: slot),
                    .setRestDuration(at: slot, duration: .quarter),
                ])))
            case 5:
                steps.append(.undo)
            default:
                steps.append(.redo)
            }
        }
        return steps
    }

    /// Runs `steps` against a session seeded with `score` and returns the fingerprint after each step. The initial
    /// fingerprint is element 0, so the array is `steps.count + 1` long.
    static func fingerprints(of steps: [EditReplayStep], startingFrom score: Score) -> [Int64] {
        let session = ScoreEditSession(score: score)
        var out = [session.score.stableFingerprint]
        for step in steps {
            switch step {
            case let .intent(intent): _ = session.apply(intent)
            case .undo: _ = session.undo()
            case .redo: _ = session.redo()
            }
            out.append(session.score.stableFingerprint)
        }
        return out
    }
}
