import Foundation

/// Part-side staff declaration (the `<Staff>` *inside* a `<Part>`).
/// Holds rendering hints; the staff's measures live in `StaffContent`.
public struct StaffDeclaration: Sendable, Equatable {
    public var staffType: String   // e.g. "stdNormal"
    public var group: String       // e.g. "pitched"
    /// MuseScore `<defaultClef>` value (e.g. "G", "F", "PERC"). Present
    /// when the Part's `<Staff>` declaration specifies a clef that the
    /// first content measure may not include explicitly. Layout engines
    /// should synthesize the opening clef from this value when the first
    /// measure lacks a `<Clef>` element.
    public var defaultClefType: String?

    public init(
        staffType: String,
        group: String,
        defaultClefType: String? = nil
    ) {
        self.staffType = staffType
        self.group = group
        self.defaultClefType = defaultClefType
    }
}
