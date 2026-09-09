import SheetMusicFoundation

/// Mints `EID`s for elements that arrive without one.
///
/// The actor is drawn fresh for each process and is **never persisted**. That
/// is deliberate: persisting an actor means persisting its counter, and every
/// path that rolls host storage backwards — a device backup restore, a cloned
/// install, a crash between minting and saving — would then reissue
/// identifiers that are still in use. With a per-process actor there is no
/// stored value to roll back and no invariant for a host to maintain.
///
/// The allocator is a value. Commands take one in and hand back the advanced
/// one, so a planner working on a scratch copy of a score consumes the same
/// range the real application does, and replay is deterministic.
public struct EIDAllocator: Sendable, Equatable {
    public let actor: UInt64
    public private(set) var counter: UInt64

    public init(actor: UInt64, counter: UInt64 = 0) {
        self.actor = actor
        self.counter = counter
    }

    /// Draws a random actor, excluding `0` and `UInt64.max` so a minted
    /// identifier can never be mistaken for the invalid sentinel or for an
    /// unset field.
    public init() {
        self.init(actor: UInt64.random(in: 1 ... (.max - 1)))
    }

    public mutating func next() -> EID {
        counter += 1
        return EID(first: actor, second: counter)
    }
}
