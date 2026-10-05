/// Permanent actor reservations for columns missing file-borne IDs. These values are part of the persistence
/// contract: changing either would detach annotations when the same original file is parsed by another version.
enum ColumnIdentity {
    /// The source column index is the counter, independent of every other element's traversal order.
    static let positionalActor = UInt64.max - 1
    /// Collisions use the first unused counter starting at one, in ascending source-column order.
    static let collisionActor = UInt64.max - 2
}

extension IdentifiedArray {
    /// Fill missing column IDs deterministically while preserving both assigned IDs and the allocator's advancement
    /// for later lane elements. A partial file may already contain another slot's positional candidate.
    mutating func assignMissingColumnIDs(using allocator: inout EIDAllocator) where Value == SystemMeasure {
        guard hasUnassignedIDs else { return }
        var used = Set(indices.map { eid(at: $0) }.filter(\.isValid))
        var collisionCounter: UInt64 = 1
        let pairs = indices.map { index -> (EID, SystemMeasure) in
            let existing = eid(at: index)
            guard !existing.isValid else { return (existing, self[index]) }
            _ = allocator.next()
            var candidate = EID(first: ColumnIdentity.positionalActor, second: UInt64(index))
            if used.contains(candidate) {
                candidate = EID(first: ColumnIdentity.collisionActor, second: collisionCounter)
                while used.contains(candidate) {
                    collisionCounter += 1
                    candidate = EID(first: ColumnIdentity.collisionActor, second: collisionCounter)
                }
            }
            used.insert(candidate)
            return (candidate, self[index])
        }
        self = IdentifiedArray(pairs)
    }
}
