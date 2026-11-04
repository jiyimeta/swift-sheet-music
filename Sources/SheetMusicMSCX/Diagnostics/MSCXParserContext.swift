import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// TaskLocal stash that lets decoders find the active
/// `MSCXDiagnosticCollector` without threading it through every
/// signature. Set by `MSCXParser.parseWithDiagnostics(...)` and
/// `MSCZReader.parseWithDiagnostics(...)`; nil outside those scopes
/// (in which case decoders skip the diagnostic and behave exactly as
/// before).
enum MSCXParserContext {
    @TaskLocal static var collector: MSCXDiagnosticCollector?

    /// Wire-format generation of the file currently being decoded, as
    /// resolved by `Score.detectVersion(root:scoreNode:)` and bound for
    /// the rest of `Score.decode(_:)`.
    ///
    /// Only needed where MuseScore changed the *default* of a field
    /// between generations, so an absent element means different things
    /// in a v3 and a v4 file (currently `<veloType>` — see
    /// `NoteVelocityType`). Nil outside a `Score.decode(_:)` scope, in
    /// which case decoders assume `.v4`.
    @TaskLocal static var version: MSCXVersion?

    /// MuseScore's integer file-format number of the file being decoded — `<museScore version="4.60">` as 460 — bound
    /// beside `version` for the rest of `Score.decode(_:)`; nil outside it, or when the attribute is absent or
    /// unreadable. `version` folds 4.0 through 4.7 into one value, but MuseScore changed how it reads a `<Marker>`'s
    /// type at 4.60 (`MarkerTypeDecoding`).
    @TaskLocal static var formatRevision: Int?

    /// The `<Division>` of the file being decoded — ticks per quarter note — bound beside `version` for the rest of
    /// `Score.decode(_:)`; nil outside it, where decoders assume MuseScore's own 480. MuseScore 4 writes a lyric's
    /// melisma as a fraction of a whole note (`<ticks_f>`), and the model counts it in ticks at this division.
    @TaskLocal static var division: Int?

    /// MuseScore's reading of `version`: major × 100 + minor, so "4.60" is 460 and "3.01" is 301
    /// (`MscLoader::readMasterScore`, `rw/mscloader.cpp:240-242`).
    static func formatRevision(versionAttribute version: String?) -> Int? {
        guard let parts = version?.split(separator: "."), parts.count == 2,
              let major = Int(parts[0]), let minor = Int(parts[1])
        else { return nil }
        return major * 100 + minor
    }

    /// The ids of every legacy note-level `<Tie id="N">` in the file being decoded, bound for the rest of
    /// `Score.decode(_:)`; nil outside it. MuseScore 2 ends a glissando with the same `<endSpanner id="N"/>` on the
    /// end note that it ends a tie with, so a note's `<endSpanner>` is a tie end only when its id is one of these —
    /// read as a tie, a glissando's end found no partner and was reported as `mscx.tie.unpairedSide`.
    @TaskLocal static var legacyTieIDs: Set<String>?

    /// The `<eid>` of every note a MuseScore 5 tie starts on, bound beside `legacyTieIDs`. MuseScore 5 writes a tie
    /// once, as a `<Tie>` on its END note whose `<startElement>` names the start note (`ties_ref.mscx` in MuseScore's
    /// MNX tests), so the start note carries nothing of its own to say it is tied.
    @TaskLocal static var museScore5TieStarts: Set<String>?

    /// Collects `legacyTieIDs` and `museScore5TieStarts` from a score subtree, in one walk.
    static func tieReferences(in node: XMLTreeNode) -> (legacyIDs: Set<String>, museScore5Starts: Set<String>) {
        var ids = Set<String>()
        var starts = Set<String>()
        var stack = [node]
        while let current = stack.popLast() {
            if current.name == "Note" {
                for tie in current.all("Tie") {
                    if let start = tie.first("startElement")?.text {
                        starts.insert(start)
                    } else if let id = tie.attributes["id"] {
                        ids.insert(id)
                    }
                }
            }
            stack.append(contentsOf: current.children)
        }
        return (ids, starts)
    }
}
