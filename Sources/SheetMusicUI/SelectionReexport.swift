// The selection model and hit-test ladder moved down to `SheetMusicLayout` in 1.10.0 so an Android host can run
// them too. Re-exported here so every Apple-side call site that imports `SheetMusicUI` for them keeps compiling —
// this file exists for source compatibility and carries no logic of its own.

@_exported import enum SheetMusicLayout.ScoreHitTarget
@_exported import struct SheetMusicLayout.ScoreHitTester
@_exported import enum SheetMusicLayout.ScoreSelection
@_exported import enum SheetMusicLayout.SelectionExpansion
