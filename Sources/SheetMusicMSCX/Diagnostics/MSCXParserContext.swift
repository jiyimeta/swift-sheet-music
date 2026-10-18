import SheetMusicCore
import SheetMusicFoundation

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
}
