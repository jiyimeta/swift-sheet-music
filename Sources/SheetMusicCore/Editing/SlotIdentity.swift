import SheetMusicFoundation

/// Identity of a slot in a deferred voice replacement. Only the landing apply mints fresh identifiers.
///
/// `.keep` and `.fresh` say what happens to the SLOT's own `EID` only — never to the identifiers
/// nested inside `element` (a chord's notes, its grace lists, each grace's own notes). Materializing
/// either case runs `assignMissingNestedIDs`, which fills only unassigned nested slots and otherwise
/// leaves them exactly as `element` already carries them. So `.fresh` alone does not make "different
/// notes": an `element` copied from elsewhere in the score keeps its source notes' identifiers even
/// under a brand-new slot `EID`, unless the caller has first called `clearNestedIDsForCopy()` on it.
/// That call is how a caller says "this is a different chord with different notes" — today only the
/// two paste commands (`PasteVoiceElement`, `PasteVoiceElements`) make it.
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
            element.assignMissingNestedIDs(using: &ids)
            return (eid, element)
        })
    }
}

/// Identity of the slot a `ReplaceVoiceElement` writes into — `.same` keeps the existing `EID`,
/// `.fresh` mints a new one, `.restore` reinstates a specific one (undo/redo). As with `SlotIdentity`,
/// this governs the SLOT only: every case runs `assignMissingNestedIDs` on the incoming element, which
/// fills unassigned nested identifiers (notes, grace lists, grace notes) and leaves already-assigned
/// ones untouched. `.fresh` does not imply new notes — a caller replacing one chord with a copy of
/// another must call `clearNestedIDsForCopy()` on the element itself first, or the copy's notes keep
/// the source's identifiers under the new slot.
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
