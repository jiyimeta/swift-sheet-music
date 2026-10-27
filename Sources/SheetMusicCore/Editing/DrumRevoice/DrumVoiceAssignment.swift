/// One row of `EditIntent.revoiceDrumStaff`'s mapping: the voice a drum pitch goes to. Scalars only, so the intent
/// stays a plain value a host can record and relay; `RevoiceDrumStaff` takes the same rows as a dictionary.
public struct DrumVoiceAssignment: Sendable, Equatable, Hashable {
    public var pitch: Int
    /// 0-based: voice 1 of the pad is index 0.
    public var voiceIndex: Int

    public init(pitch: Int, voiceIndex: Int) {
        self.pitch = pitch
        self.voiceIndex = voiceIndex
    }
}
