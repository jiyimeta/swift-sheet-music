# SheetMusicRenderWindows resources

What a Windows host needs to draw and lay out a score, bundled with the
module so it always matches the package revision
(`ScoreSurface.init()`, `ScoreSurface.bundledFontFiles`,
`installWindowsFontMetrics()`). Every file but the metrics table is a
copy; edit the source, then copy it here.

| File | Copied from |
|---|---|
| `Bravura.otf` | `Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.otf` |
| `Bravura.LICENSE.txt` | `Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.LICENSE.txt` |
| `Edwin-Roman.otf`, `Edwin-Italic.otf`, `Edwin-Bold.otf`, `Edwin-BdIta.otf` | `Examples/Apple/SheetMusicExample/Resources/Fonts/` (same names) |
| `Edwin.LICENSE.txt` | `Examples/Apple/SheetMusicExample/Resources/Fonts/LICENSE.txt` |
| `sheet-music.smft` | generated here: `swift run GenFontMetrics --family-styles Sources/SheetMusicRenderWindows/Resources/sheet-music.smft` |

The table is not the web's copy. Its Bravura and regular Edwin records
are the web table's, but its bold, italic and bold-italic records
measure Edwin's own styled files above — the faces this renderer draws
and the PDF writer embeds — where the web's keep the regular advances
and stroke or shear the regular outlines, as the browser draws them.

`Tests/SheetMusicTests/WindowsBundledResourcesTests.swift` pins every
copy here byte-equal to its source, and `WindowsMetricsTableTests.swift`
pins the table to the web's regular records and to the styled files, so
a regenerated web table or an updated font fails CI on the Mac until
this folder follows.

Bravura (© Steinberg Media Technologies GmbH) and Edwin (© 2021
MuseScore Limited) are under the SIL Open Font License 1.1; the license
texts ship beside the fonts.

SwiftPM copies this folder (`.copy("Resources")`) into
`swift-sheet-music_SheetMusicRenderWindows.resources`, beside the
executable it builds. A deployed app must carry that folder beside its
executable too, or `Bundle.module` cannot find it.
