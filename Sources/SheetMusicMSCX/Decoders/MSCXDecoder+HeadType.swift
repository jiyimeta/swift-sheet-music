import SheetMusicFoundation

/// Namespace for MSCX decoder constants surfaced for the Phase 6
/// render-coverage sync test (RenderCoverageSyncTests).
/// C++: src/engraving/types/typesconv.cpp:1145-1235
enum MSCXDecoder {}

extension MSCXDecoder {
    /// Every valid MS4 `<head>` token.
    ///
    /// Strings in this set are returned verbatim by `Note.decodeHeadType`;
    /// anything outside it (that isn't `"custom"`) triggers an
    /// `mscx.note.unsupportedHeadType` diagnostic and a `nil` return.
    ///
    /// Internal — `@testable import SheetMusicMSCX` surfaces it for
    /// `RenderCoverageSyncTests` (Task 6.1).
    ///
    /// C++: `src/engraving/dom/note.cpp:89-322`,
    ///      `src/engraving/types/typesconv.cpp:1145-1235`.
    static let knownHeadTokens: Set = [
        // ── Shape / group heads (A.1 table, note.cpp:89-159) ──────────────────
        "normal", "cross", "plus", "xcircle", "withx",
        "triangle-up", "triangle-down",
        "slashed1", "slashed2",
        "diamond", "diamond-old",
        "circled", "circled-large",
        "large-arrow", "altbrevis", "slash", "large-diamond",
        "sol", "la", "fa", "mi", "do", "re", "ti",
        "heavy-cross", "heavy-cross-hat",
        "do-walker", "re-walker", "ti-walker",
        "do-funk", "re-funk", "ti-funk",
        "swiss-rudiments-flam", "swiss-rudiments-double",
        // ── Named-solfège heads (note.cpp:160-176) ───────────────────────────
        // Syllables: Do Di Ra Re Ri Me Mi Fa Fi Se So Le La Li Te Ti Si
        "do-name", "di-name", "ra-name", "re-name", "ri-name",
        "me-name", "mi-name", "fa-name", "fi-name", "se-name",
        "sol-name", "le-name", "la-name", "li-name", "te-name",
        "ti-name", "si-name",
        // ── Named-pitch heads (note.cpp:178-200) ─────────────────────────────
        // Pitches A–G (natural / sharp / flat) + H / H-sharp
        "a-name", "a-sharp-name", "a-flat-name",
        "b-name", "b-sharp-name", "b-flat-name",
        "c-name", "c-sharp-name", "c-flat-name",
        "d-name", "d-sharp-name", "d-flat-name",
        "e-name", "e-sharp-name", "e-flat-name",
        "f-name", "f-sharp-name", "f-flat-name",
        "g-name", "g-sharp-name", "g-flat-name",
        "h-name", "h-sharp-name",
    ]
}
