import SheetMusicFoundation

/// Identity of a slot in a deferred voice replacement. Only the landing apply mints fresh identifiers.
public enum SlotIdentity: Sendable, Equatable {
    case keep(EID)
    case fresh
}

public struct VoiceSlot: Sendable, Equatable {
    public var identity: SlotIdentity
    public var element: VoiceElement

    public init(identity: SlotIdentity, element: VoiceElement) {
        self.identity = identity
        self.element = element
    }

    static func materialize(_ slots: [VoiceSlot], using ids: inout EIDAllocator) -> IdentifiedArray<VoiceElement> {
        IdentifiedArray(slots.map { slot in
            let eid: EID
            switch slot.identity {
            case let .keep(kept):
                assert(kept.isValid, "a kept voice slot requires an assigned identifier")
                eid = kept
            case .fresh:
                eid = ids.next()
            }
            var element = slot.element
            element.assignMissingGraceIDs(using: &ids)
            return (eid, element)
        })
    }
}

public enum ElementIdentity: Sendable, Equatable {
    case same
    case fresh
    case restore(EID)
}

extension IdentifiedArray {
    /// A deferred snapshot; unassigned identities must not be laundered into fresh slots.
    func voiceSlots() -> [VoiceSlot] where Value == VoiceElement {
        assert(!hasUnassignedIDs, "a voice snapshot requires assigned identifiers")
        return indices.map { VoiceSlot(identity: .keep(eid(at: $0)), element: self[$0]) }
    }

    /// Preserve slot identities when a range is carried to another voice or position.
    func identifiedPairs<Positions: Sequence>(in positions: Positions) -> [(EID, VoiceElement)]
        where Value == VoiceElement, Positions.Element == Int
    {
        positions.map { (eid(at: $0), self[$0]) }
    }
}
