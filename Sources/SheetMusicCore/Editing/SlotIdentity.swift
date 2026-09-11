import SheetMusicFoundation

/// Identity of a slot in a deferred voice replacement. Only the landing apply mints fresh identifiers.
///
/// `.keep` and `.fresh` say what happens to the SLOT's own `EID` only — never directly to the
/// identifiers nested inside `element` (a chord's notes, its grace lists, each grace's own notes).
/// `.keep` always leaves them exactly as `element` already carries them: `assignMissingNestedIDs`
/// fills only unassigned nested slots. `.fresh` defaults to a NEW element — its nested identifiers are
/// cleared before assignment, because a brand-new slot ordinarily means a different chord with
/// different notes, not the same notes at a new address. The rare exception (nested elements that
/// MOVE rather than being copied — e.g. a grace list handed from one chord to another across a split)
/// opts out via `VoiceSlot`'s `nestedIdentity: .carried`.
public enum SlotIdentity: Sendable, Equatable {
    case keep(EID)
    case fresh
}

public struct VoiceSlot: Sendable, Equatable {
    /// Whether a `.fresh` slot's nested identifiers (a chord's notes, its grace lists, each grace's
    /// own notes) are cleared before assignment, or carried through unchanged. Irrelevant to `.keep`,
    /// which always carries them regardless of this value.
    enum NestedIdentity: Sendable, Equatable {
        /// The default: `element` is a different chord with different notes, so its nested
        /// identifiers are cleared and reassigned fresh.
        case cleared
        /// The opt-out: `element`'s nested identifiers are the SAME notes the performer was looking
        /// at, moved rather than copied, and must survive under the new slot unchanged.
        case carried
    }

    public var identity: SlotIdentity
    public var element: VoiceElement
    /// Left in the synthesized `==` deliberately, unlike `TupletSpan.eid`'s exclusion: this is not
    /// bookkeeping identity riding alongside a value, it is an instruction that changes what
    /// `materialize` does with `element`'s nested identifiers — two slots that differ only here are
    /// not equivalent requests, so equality must see the difference.
    var nestedIdentity: NestedIdentity

    public init(identity: SlotIdentity, element: VoiceElement) {
        self.init(identity: identity, element: element, nestedIdentity: .cleared)
    }

    init(identity: SlotIdentity, element: VoiceElement, nestedIdentity: NestedIdentity) {
        self.identity = identity
        self.element = element
        self.nestedIdentity = nestedIdentity
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
            if case .fresh = slot.identity, slot.nestedIdentity == .cleared {
                element = element.clearingNestedIDsForCopy()
            }
            element.assignMissingNestedIDs(using: &ids)
            return (eid, element)
        })
    }
}

/// Identity of the slot a `ReplaceVoiceElement` writes into — `.same` keeps the existing `EID`,
/// `.fresh` mints a new one, `.restore` reinstates a specific one (undo/redo). As with `SlotIdentity`,
/// this governs the SLOT only. `.same` and `.restore` run `assignMissingNestedIDs` on the incoming
/// element as-is, filling only unassigned nested identifiers and leaving already-assigned ones
/// untouched — right for `.restore` in particular, since undo reinstates the very notes that were
/// there before. `.fresh` clears the element's nested identifiers unconditionally before assignment:
/// a fresh slot means a different chord with different notes, so a caller replacing one chord with a
/// copy of another needs no extra step — `ReplaceVoiceElement` clears the copy's notes itself.
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
