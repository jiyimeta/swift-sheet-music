import SheetMusicFoundation

/// Mints `EID`s for elements that arrive without one.
///
/// Allocators from `init()` are drawn fresh for each process and are **never
/// persisted** — that is deliberate and unconditional. Persisting an actor
/// means persisting its counter, and every path that rolls host storage
/// backwards — a device backup restore, a cloned install, a crash between
/// minting and saving — would then reissue identifiers that are still in use.
/// With a per-process actor there is no stored value to roll back and no
/// invariant for a host to maintain.
///
/// The allocator is a value. Commands take one in and hand back the advanced
/// one, so a planner working on a scratch copy of a score consumes the same
/// range the real application does, and replay is deterministic.
/// Allocators restored via `init(actor:counter:)` for deterministic replay
/// must not have an actor of `0` or `UInt64.max` — those values would allow
/// `next()` to mint identifiers indistinguishable from the invalid sentinel.
public struct EIDAllocator: Sendable, Equatable {
    public let actor: UInt64
    public private(set) var counter: UInt64

    /// Restores an allocator from saved values, for deterministic replay
    /// (e.g. when a planner applies commands to a scratch copy of a score).
    ///
    /// - Precondition: `actor` must not be `0` or `UInt64.max`. A caller
    ///   passing either value is programming error, not a runtime condition to
    ///   recover from — `first` is always the actor, so an actor of
    ///   `UInt64.max` would allow `next()` to mint `EID.invalid`, which would
    ///   make an identified element indistinguishable from an unidentified one.
    public init(actor: UInt64, counter: UInt64 = 0) {
        precondition(
            actor != 0 && actor != .max,
            "actor must not be 0 or .max; first is the actor, so .max would allow next() to mint EID.invalid",
        )
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
