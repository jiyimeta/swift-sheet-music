import Foundation

/// Part-side staff declaration (the `<Staff>` *inside* a `<Part>`).
/// Holds rendering hints; the staff's measures live in `StaffContent`.
public struct StaffDeclaration: Sendable, Equatable {
    public var staffType: String   // e.g. "stdNormal"
    public var group: String       // e.g. "pitched"

    public init(staffType: String, group: String) {
        self.staffType = staffType
        self.group = group
    }
}
