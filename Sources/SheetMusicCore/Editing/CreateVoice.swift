import SheetMusicFoundation

/// Append a voice to one measure, filled with a single full-measure rest.
///
/// `ReplaceVoiceElements` requires the target voice to already exist and nothing else in this package creates
/// one, so this is what a write into voice 2 of a bar that has only voice 1 has to go through first — the case
/// drum note entry hits constantly, since a bass drum belongs to the feet voice whether or not the bar has one.
///
/// Voices are an array, so only the NEXT index can be created: asking for voice 2 of a one-voice measure would
/// leave a hole where voice 1 should be, and is refused. Asking for a voice that already exists is refused too,
/// rather than quietly emptying it.
///
/// The fill is one `.measure` rest — "however long this bar is" — which is what `Score.blank` writes into an
/// empty bar and what makes a pickup measure need no special case.
public struct CreateVoice: EditCommand {
    public let staff: StaffAddress
    public let measureIndex: Int
    public let voiceIndex: Int
    private let restoredVoice: Voice?

    public init(staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        restoredVoice = nil
    }

    init(restoring voice: Voice, staff: StaffAddress, measureIndex: Int, voiceIndex: Int) {
        self.staff = staff
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        restoredVoice = voice
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: 0)
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else {
            throw Self.refused(.staffNotFound(staff))
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        guard score.parts[p].staves[s].measures.indices.contains(measureIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let voiceCount = score.parts[p].staves[s].measures[measureIndex].voices.count
        guard voiceIndex >= voiceCount else {
            throw Self.refused(.voiceAlreadyExists(
                staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex,
            ))
        }
        guard voiceIndex == voiceCount else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        score.parts.updateValue(at: p) { partValue in
            partValue.staves.updateValue(at: s) { staffValue in
                staffValue.measures[measureIndex].voices.append(
                    restoredVoice ?? MeasureStructure.freshMeasureRest(using: &ids),
                )
            }
        }
        return RemoveVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
    }
}

/// `CreateVoice`'s inverse: drop the LAST voice of a measure again. Not public — a host has no reason to remove
/// a voice outright, and `CreateVoice` is the only thing that can put the score in the state this undoes.
///
/// It drops the voice wholesale rather than restoring its contents, which is exact because `CreateVoice` created
/// it empty. Anything written into that voice afterwards is undone by its own inverse first — the undo stack is
/// a stack.
struct RemoveVoice: EditCommand {
    let staff: StaffAddress
    let measureIndex: Int
    let voiceIndex: Int

    var affectedLocation: VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: 0)
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard score.parts.indices.contains(staff.partIndex),
              score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
        else {
            throw Self.refused(.staffNotFound(staff))
        }
        let p = staff.partIndex
        let s = staff.staffIndexInPart
        guard score.parts[p].staves[s].measures.indices.contains(measureIndex),
              score.parts[p].staves[s].measures[measureIndex].voices.indices.contains(voiceIndex),
              voiceIndex == score.parts[p].staves[s].measures[measureIndex].voices.count - 1
        else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let removed = score.parts[p].staves[s].measures[measureIndex].voices[voiceIndex]
        score.parts.updateValue(at: p) { partValue in
            partValue.staves.updateValue(at: s) { staffValue in
                staffValue.measures[measureIndex].voices.removeLast()
            }
        }
        return CreateVoice(restoring: removed, staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
    }
}
