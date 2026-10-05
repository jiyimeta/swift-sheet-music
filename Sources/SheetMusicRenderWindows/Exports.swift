// The pages a Windows host hands the surface (`ScorePages`, `ScorePageOptions`, the page geometry) live in the portable
// `SheetMusicPages`, which a PDF writer shares; a host that imports this module keeps seeing them as before.
@_exported import SheetMusicPages
