import SheetMusicFoundation

/// One voice of one measure of one staff — the container a `VoiceElementID` names an element of. Member of the
/// closed reference family; see `MeasureRef`.
public struct VoiceRef: Hashable, Sendable {
    public var staff: StaffAddress
    public var measureIndex: Int
    public var voiceIndex: Int

    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
    }

    /// The voice a `VoiceElementID` belongs to.
    public init(_ id: VoiceElementID) {
        self.init(staff: id.staff, measureIndex: id.measureIndex, voiceIndex: id.voiceIndex)
    }
}
