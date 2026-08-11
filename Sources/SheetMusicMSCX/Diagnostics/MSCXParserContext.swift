import Foundation
import SheetMusicCore

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
}
