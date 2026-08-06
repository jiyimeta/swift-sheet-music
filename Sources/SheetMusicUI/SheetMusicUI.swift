// `SheetMusicUI` exposes `LayoutDocument`, `LayoutSystem`, and other
// `SheetMusicLayout` types in its public API surface (e.g. as
// parameters to `ScoreView` and `ScoreHitTester`). Re-export the
// dependent modules so consumers only need `import SheetMusicUI`
// to use those types — mirroring the umbrella `SheetMusic` pattern.
//
// The selection model and hit-test ladder (`ScoreSelection`, `ScoreHitTarget`, `ScoreHitTester` and its
// `itemIDs(in:)` marquee extension, `SelectionExpansion`) moved down into `SheetMusicLayout` in 1.10.0 so an
// Android host could use them too. This line is what still lets every Apple-side call site that imports only
// `SheetMusicUI` — including Folino's, until SP2's cutover — see them without a source change; there is no
// separate per-symbol re-export for them. `Tests/SheetMusicTests/SelectionReexportTests.swift` compiles that
// `SheetMusicUI`-only path so this stays true.
@_exported import SheetMusicCore
@_exported import SheetMusicLayout
