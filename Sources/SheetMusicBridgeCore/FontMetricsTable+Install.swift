import SheetMusicFoundation
import SheetMusicLayout

/// Installs the measured font-metrics table (`sheet-music.smft`, as the web and Android builds ship it) as the layout's
/// `FontMetrics.provider` — what a host without CoreText does once, before its first layout. Windows is such a host:
/// its layout measures glyphs and text from the table, and its renderer draws them from the font files.
///
/// Throws when the bytes do not decode (empty bytes are truncated); the provider is left as it was.
public func installFontMetricsTable(_ bytes: Data) throws {
    let table = try FontMetricsTable.decode(bytes)
    FontMetrics.provider = makeFontMetricsTableProvider(table: table)
}
