import SheetMusicFoundation

/// A deferred tuplet. Index endpoints name positions in the accompanying voice payload.
public struct TupletSlot: Sendable, Equatable {
    public var identity: SlotIdentity
    public var tuplet: Tuplet

    public init(identity: SlotIdentity, tuplet: Tuplet) {
        self.identity = identity
        self.tuplet = tuplet
    }

    static func materialize(
        _ slots: [TupletSlot], elements: IdentifiedArray<VoiceElement>, using ids: inout EIDAllocator,
    ) -> IdentifiedArray<Tuplet> {
        IdentifiedArray(slots.map { slot in
            var tuplet = slot.tuplet
            tuplet.first = tuplet.first.resolved(in: elements)
            tuplet.last = tuplet.last.resolved(in: elements)
            precondition(
                tuplet.first.index(in: elements) >= 0 && tuplet.last.index(in: elements) >= 0,
                "payload tuplet endpoint must name a materialized member",
            )
            switch slot.identity {
            case let .keep(eid):
                assert(eid.isValid, "a kept tuplet requires an assigned identifier")
                return (eid, tuplet)
            case .fresh:
                return (ids.next(), tuplet)
            }
        })
    }
}

extension IdentifiedArray {
    func tupletSlots() -> [TupletSlot] where Value == Tuplet {
        assert(!hasUnassignedIDs, "a tuplet snapshot requires assigned identifiers")
        return indices.map { TupletSlot(identity: .keep(eid(at: $0)), tuplet: self[$0]) }
    }
}
