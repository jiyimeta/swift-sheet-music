import SheetMusicBridgeCore
import SheetMusicFoundation
import SheetMusicLayout

/// Installs the measured font-metrics table (`sheet-music.smft`, as the web and Android builds ship it) as the layout's
/// `FontMetrics.provider` — what a host without CoreText does once, before its first layout. Windows is such a host:
/// its layout measures glyphs and text from the table, and its renderer draws them from the font files. Android is
/// another, for a print laid out in Swift (`ScorePages.compute`).
///
/// Lives in `SheetMusicPages` rather than beside the table it decodes because this is a product and
/// `SheetMusicBridgeCore` is not: a host can only reach it from here.
///
/// Throws when the bytes do not decode (empty bytes are truncated); the provider is left as it was.
public func installFontMetricsTable(_ bytes: Data) throws {
    FontMetrics.provider = try fontMetricsTableProvider(bytes)
}

/// The provider `installFontMetricsTable` installs, made without installing it — for a computation that lays out with
/// the table inside `FontMetrics.withProvider(_:operation:)` while the rest of the process keeps its own provider (a
/// video on Apple, laid out as Android lays it out). Tests check this rather than the process-wide provider too: every
/// suite in the test process shares that one, and a test that swaps it and puts it back can put back a stale value
/// over another suite's install.
///
/// What it answers for what the table does not carry:
/// - A face the table lacks is measured by `StubFontMetricsProvider`.
/// - A character a carried face lacks — Edwin's missing CJK, most often — gets the stub's per-character estimate.
/// - `renderingTextFont` answers Edwin for every face that is not Bravura (semibold as regular): the table carries no
///   other text face, so a host draws text in Edwin and the layout measures it so.
///
/// Throws when the bytes do not decode (empty bytes are truncated).
public func fontMetricsTableProvider(_ bytes: Data) throws -> any FontMetricsProvider {
    try makeFontMetricsTableProvider(table: FontMetricsTable.decode(bytes))
}
