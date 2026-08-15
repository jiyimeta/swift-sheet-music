// `SheetMusicLayout`'s public API is written in `SheetMusicCore`'s vocabulary — `Score`, `ScoreItemID`,
// `StaffAddress`, `NoteDuration` all appear in its signatures — so a consumer importing this module already needs
// those names in scope. Re-exporting says so, and mirrors what `SheetMusicUI` does one layer up.
//
// It also keeps `DurationInterpretation` reachable from `import SheetMusicLayout` alone. That type lived here until
// it moved down into `SheetMusicCore`, where it belongs: splitting a written duration into a base value plus
// augmentation dots is arithmetic over `NoteDuration` and involves no layout at all. The move is what lets a
// platform-neutral editing core — which depends on Core but must not depend on layout — light the right length key.
@_exported import SheetMusicCore
