import Foundation

/// Top-level `<Staff id="N">` content (the actual measures of one staff).
/// C++: top-level `<Staff>` block in mscx (separate from the `<Part><Staff>` declaration).
public struct StaffContent: Sendable, Equatable {
    public var id: Int
    public var measures: [Measure]

    public init(id: Int, measures: [Measure]) {
        self.id = id
        self.measures = measures
    }
}
