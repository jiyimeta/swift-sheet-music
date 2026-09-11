import SheetMusicCore
import SheetMusicXMLTools

/// The single place that reads and writes MuseScore's `<eid>` child —
/// the element identifier as it appears on disk.
///
/// A decoded identifier lands as an *assigned slot*; callers build their
/// identified arrays with `.invalid` where the file carried nothing, and
/// the existing `assignMissingIDs` chokepoints fill the gaps. This type
/// mints nothing itself.
enum EIDXML {
    static let childName = "eid"

    /// `.invalid` when the child is absent or malformed — "no identifier
    /// yet", not an error. The parser policy here is permissive for
    /// real-world files: an unreadable identifier is exactly the state the
    /// assignment pass exists to fill.
    static func decode(from node: XMLTreeNode) -> EID {
        guard let child = node.first(childName),
              let eid = EID(string: child.text)
        else { return .invalid }
        return eid
    }

    /// Nil for an unassigned identifier, so callers can
    /// `append(contentsOf:)` unconditionally.
    static func node(for eid: EID) -> XMLTreeNode? {
        guard eid.isValid else { return nil }
        return XMLTreeNode(name: childName, text: eid.stringValue)
    }
}
