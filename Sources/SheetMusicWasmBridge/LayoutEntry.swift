import JavaScriptKit
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// `FoundationEssentials` has no `CGFloat`; anchor to Layout's stub the same
    /// way the bridge's other geometry files do. Swift's imports are
    /// file-scoped, so this has to be repeated per file that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Install the font-metrics table the layout engine measures with — Bravura's
/// glyph geometry and Edwin's text metrics, in one payload since SMFT v4.
/// Returns `false` on an empty or undecodable payload, which is also what a
/// table written for an older format version gets.
///
/// Android: `nativeInstallSMuFLMetrics`, fed by `FontMetricsBuilder.kt`
/// measuring `Paint.getTextPath` at runtime. The browser has no equivalent
/// geometric measurement — Canvas2D's `actualBoundingBox*` reports rasterized
/// ink, the quantity the Android builder explicitly avoided — so the web host
/// loads a table generated at build time from CoreText by
/// `Tools/GenFontMetrics` and served as `assets/sheet-music.smft`.
///
/// The name predates the text face and is kept for source compatibility with
/// hosts; `FontMetricsTable` is what it actually installs.
///
/// Without a table the engraver falls back to `StubFontMetricsProvider`'s
/// rectangle approximations and the spacing is visibly wrong, so a host that
/// ignores the `false` will notice.
@JS public func installSMuFLMetrics(bytes: JSUint8Array) -> Bool {
    let data = bytes.bridgedData
    guard !data.isEmpty else { return false }
    do {
        FontMetrics.provider = try makeFontMetricsTableProvider(
            table: FontMetricsTable.decode(data),
        )
        return true
    } catch {
        return false
    }
}

/// Lay out `handle` and return the draw program as `DrawProgramFlat` bytes.
/// Empty for an unknown handle.
///
/// Android: `nativeComputeLayout`, which also takes a `LayoutOptionsWire` blob
/// carrying the display inspector's settings.
///
/// The laid-out document is stored in `LayoutDocumentCache` so `pageBreaks` —
/// and, once playback and editing arrive, cursor and hit-test lookups — do not
/// re-engrave.
@JS public func computeLayout(
    handle: Int,
    pageWidthMM: Double,
    pageHeightMM: Double,
    options: LayoutOptions,
) -> JSUint8Array {
    guard let score = scoreTable.value(for: Int64(handle)) else { return JSUint8Array(length: 0) }
    let wire = options.wire
    let result = LayoutBridge.computeWithPages(
        score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: wire,
    )
    LayoutDocumentCache.store(
        handle: Int64(handle),
        document: result.document,
        filteredScore: result.filteredScore,
        hiddenStaves: wire.hiddenStaffAddresses,
        options: wire,
        pageWidthMM: pageWidthMM,
        pageHeightMM: pageHeightMM,
    )
    return DrawProgramFlat.encode(pages: result.pages).bridgedUint8Array
}

/// Page-boundary document-Y offsets in millimetres for the cached layout of
/// `handle`: `[0, top1, …, contentBottom]`, one entry per boundary plus the
/// content bottom, so the count is `pageCount + 1`. Empty when no layout has
/// been computed for the handle.
///
/// Android: `nativePageBreaks`, which returns the same sequence as a
/// `PageBreaksWire` payload. BridgeJS lowers `[Double]` through the typed-array
/// fast path, so a wire format would buy nothing here.
@JS public func pageBreaks(handle: Int, pageHeightMM: Double) -> [Double] {
    guard let entry = LayoutDocumentCache.entry(for: Int64(handle)),
          !entry.document.systems.isEmpty
    else { return [] }
    let mmToPt = 72.0 / 25.4
    let pageHeightPt = CGFloat(pageHeightMM * mmToPt)
    let breakPolicy: LayoutBreakPolicy = entry.options.honorLayoutBreaks == 1 ? .honor : .ignoreAll
    let ranges = LayoutPaginator.paginate(
        systems: entry.document.systems, pageHeight: pageHeightPt, policy: breakPolicy,
    )
    guard !ranges.isEmpty else { return [] }
    var offsetsMM: [Double] = []
    for (i, range) in ranges.enumerated() {
        if i == 0 {
            offsetsMM.append(0)
        } else {
            let previous = entry.document.systems[range.lowerBound - 1]
            offsetsMM.append(Double(previous.origin.y + previous.size.height) / mmToPt)
        }
    }
    let last = entry.document.systems[entry.document.systems.count - 1]
    offsetsMM.append(Double(last.origin.y + last.size.height) / mmToPt)
    return offsetsMM
}
