// `SheetMusicUI` exposes `LayoutDocument`, `LayoutSystem`, and other
// `SheetMusicLayout` types in its public API surface (e.g. as
// parameters to `ScoreView` and `ScoreHitTester`). Re-export the
// dependent modules so consumers only need `import SheetMusicUI`
// to use those types — mirroring the umbrella `SheetMusic` pattern.
@_exported import SheetMusicCore
@_exported import SheetMusicLayout
