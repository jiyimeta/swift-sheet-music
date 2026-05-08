import Foundation

extension Score {
    /// 1-based displayed measure number, with `irregular` measures
    /// excluded from the running count. Returns `nil` for an irregular
    /// measure (no label is drawn for it).
    ///
    /// Uses staff 0 as the source of truth for the `irregular` flag —
    /// per-staff divergence is out of scope.
    public func displayedMeasureNumber(at index: Int) -> Int? {
        guard let staff = allStaves.first?.staff,
              staff.measures.indices.contains(index)
        else { return nil }
        if staff.measures[index].irregular { return nil }
        var count = 0
        for i in 0 ... index where !staff.measures[i].irregular {
            count += 1
        }
        return count
    }
}
