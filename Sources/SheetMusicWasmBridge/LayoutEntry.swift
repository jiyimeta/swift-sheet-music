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

/// Install the SMuFL glyph-metrics table the layout engine measures with.
/// Returns `false` on an empty or undecodable payload.
///
/// Android: `nativeInstallSMuFLMetrics`, fed by `BravuraMetricsBuilder.kt`
/// measuring `Paint.getTextPath` at runtime. The browser has no equivalent
/// geometric measurement — Canvas2D's `actualBoundingBox*` reports rasterized
/// ink, the quantity the Android builder explicitly avoided — so the web host
/// loads a table generated at build time from CoreText by
/// `Tools/GenBravuraMetrics`.
///
/// Without a table the engraver falls back to `StubFontMetricsProvider`'s
/// rectangle approximations and the spacing is visibly wrong, so a host that
/// ignores the `false` will notice.
@JS public func installSMuFLMetrics(bytes: JSUint8Array) -> Bool {
    let data = bytes.bridgedData
    guard !data.isEmpty else { return false }
    do {
        FontMetrics.provider = try makeSMuFLMetricsTableProvider(
            table: SMuFLMetricsTable.decode(data),
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
/// carrying the display inspector's settings. The wasm surface does not expose
/// options yet and uses `.verticalDefault`, exactly as `LayoutBridge.compute`
/// does.
///
/// The laid-out document is stored in `LayoutDocumentCache` so `pageBreaks` —
/// and, once playback and editing arrive, cursor and hit-test lookups — do not
/// re-engrave.
@JS public func computeLayout(handle: Int, pageWidthMM: Double, pageHeightMM: Double) -> JSUint8Array {
    guard let score = scoreTable.value(for: Int64(handle)) else { return JSUint8Array(length: 0) }
    let options = LayoutOptionsWire.verticalDefault
    let result = LayoutBridge.computeWithPages(
        score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: options,
    )
    LayoutDocumentCache.store(
        handle: Int64(handle),
        document: result.document,
        filteredScore: result.filteredScore,
        hiddenStaves: options.hiddenStaffAddresses,
        options: options,
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
    guard let document = LayoutDocumentCache.value(for: Int64(handle)),
          !document.systems.isEmpty
    else { return [] }
    let mmToPt = 72.0 / 25.4
    let pageHeightPt = CGFloat(pageHeightMM * mmToPt)
    let ranges = LayoutPaginator.paginate(
        systems: document.systems, pageHeight: pageHeightPt, policy: .honor,
    )
    guard !ranges.isEmpty else { return [] }
    var offsetsMM: [Double] = []
    for (i, range) in ranges.enumerated() {
        if i == 0 {
            offsetsMM.append(0)
        } else {
            let previous = document.systems[range.lowerBound - 1]
            offsetsMM.append(Double(previous.origin.y + previous.size.height) / mmToPt)
        }
    }
    let last = document.systems[document.systems.count - 1]
    offsetsMM.append(Double(last.origin.y + last.size.height) / mmToPt)
    return offsetsMM
}
