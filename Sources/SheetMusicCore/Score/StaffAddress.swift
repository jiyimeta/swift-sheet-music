import Foundation

/// Path-based address of a `Staff` inside a `Score`:
/// `score.parts[partIndex].staves[staffIndexInPart]`.
///
/// `Comparable` orders by `(partIndex, staffIndexInPart)` lexicographically,
/// matching the engraver's top-to-bottom display order.
public struct StaffAddress: Hashable, Sendable, Comparable {
    public let partIndex: Int
    public let staffIndexInPart: Int

    public init(partIndex: Int, staffIndexInPart: Int) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.partIndex, lhs.staffIndexInPart)
            < (rhs.partIndex, rhs.staffIndexInPart)
    }
}

extension Score {
    /// Every staff in display order. Replaces the old flat
    /// `score.staves` iteration: enumerate to recover the legacy
    /// flat staffIndex if some downstream still needs it.
    public var allStaves: [(address: StaffAddress, staff: Staff)] {
        var result: [(address: StaffAddress, staff: Staff)] = []
        for (p, part) in parts.enumerated() {
            for (s, staff) in part.staves.enumerated() {
                result.append(
                    (
                        StaffAddress(partIndex: p, staffIndexInPart: s),
                        staff,
                    ),
                )
            }
        }
        return result
    }

    /// Number of staves in display order across all parts.
    public var totalStaffCount: Int {
        parts.reduce(0) { $0 + $1.staves.count }
    }

    /// Resolve an address to its `Staff`, or `nil` if out of range.
    public subscript(address: StaffAddress) -> Staff? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        let part = parts[address.partIndex]
        guard part.staves.indices.contains(address.staffIndexInPart) else {
            return nil
        }
        return part.staves[address.staffIndexInPart]
    }

    /// Resolve to the owning `Part`.
    public func part(at address: StaffAddress) -> Part? {
        guard parts.indices.contains(address.partIndex) else { return nil }
        return parts[address.partIndex]
    }
}
