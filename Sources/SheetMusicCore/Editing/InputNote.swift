import Foundation

/// Replaces a rest with a single-note chord of the same duration.
///
/// The simplest "drop a note" operation: target a rest, supply pitch
/// + tpc, and the command builds a fresh chord whose `duration`
/// matches the rest. The inverse re-installs the rest.
///
/// ## `.measure` rests
///
/// A full-measure rest is spelled `.measure` — "however long this bar
/// is" — which is a REST-ONLY duration: it is the one thing a chord
/// may not say. MuseScore's `Chord::write` has no `measure`
/// durationType, and this package's own `MSCXEncoder` traps rather
/// than emit one. So writing a note into an empty bar resolves the
/// bar's actual length instead of inheriting the placeholder.
///
/// The inverse still restores the rest exactly as it was spelled —
/// the resolution happens on the way in only, so undo puts the
/// `.measure` rest back rather than a same-length whole rest.
///
/// Getting this wrong stays invisible for a long time: layout
/// resolves `.measure` against the bar and draws the note correctly,
/// so the score looks right and only the eventual SAVE fails, far
/// from the edit that caused it.
public struct InputNote: EditCommand {
    public let location: RestID
    public let pitch: Int
    public let tpc: Int

    public init(at location: RestID, pitch: Int, tpc: Int) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(location)
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let rest = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "InputNote: no rest at \(location)",
            )
        }
        let chord = Chord(
            duration: rest.duration.resolved(
                in: score.effectiveMeasureDuration(
                    at: location.staff, measureIndex: location.measureIndex,
                ),
            ),
            notes: [Note(pitch: pitch, tpc: tpc)],
        )
        let veID = VoiceElementID(location)
        score[veID] = .chord(chord)
        return ReplaceVoiceElement(at: veID, with: .chord(rest))
    }
}
