import Foundation

/// Replaces a rest with a single-note chord of the same duration.
///
/// The simplest "drop a note" operation: target a rest, supply pitch
/// + tpc, and the command builds a fresh chord whose `duration`
/// matches the rest. The inverse re-installs the rest.
public struct InputNote: EditCommand {
    public let location: RestID
    public let pitch: Int
    public let tpc: Int

    public init(at location: RestID, pitch: Int, tpc: Int) {
        self.location = location
        self.pitch = pitch
        self.tpc = tpc
    }

    public var affectedLocation: VoiceElementID { VoiceElementID(location) }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let rest = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "InputNote: no rest at \(location)")
        }
        let chord = Chord(
            duration: rest.duration,
            notes: [Note(pitch: pitch, tpc: tpc)])
        let veID = VoiceElementID(location)
        score[veID] = .chord(chord)
        return ReplaceVoiceElement(at: veID, with: .rest(rest))
    }
}
