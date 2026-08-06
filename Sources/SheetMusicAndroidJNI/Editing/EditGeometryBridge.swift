import Foundation
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`/`CGPoint`, clashing with
    /// SheetMusicLayout's stubs. Anchor to the Layout definitions — see `NearestCursorBridge.swift`'s copy of
    /// this same guard for the full explanation (module-local-wins doesn't help here: this is a different
    /// target from `SheetMusicLayout`).
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

// Editing-geometry JNI bridge: the last three entry points spec §5.3 names — a tap-to-item hit-test, an
// item's caret rect, and a selection-tinted re-encode of the already-cached draw program. All three read
// `LayoutDocumentCache`, never write it; only `nativeComputeLayout` (`JNISymbols.swift`) populates the cache.
//
// ## Addressing: full-score in, filtered-document out and back in
//
// `nativeEditingHitTest` returns an engine-ready, full-score-addressed `ScoreItemID` — the same convention
// `nativeNearestCursor` (`NearestCursorBridge.swift`) uses for its `ScoreCursor`, via the same
// `Score.engineCursorForFilteredTap` helper, so the returned ID drops straight into an edit intent without a
// second re-addressing implementation. That full-score address is what a host naturally keeps as "the
// selected item" (it is also what edit intents need), so `nativeEditingCaretFrame` and
// `nativeEncodeDrawProgram` both re-address it back into the cached (filtered) document's own addressing
// before doing any geometry lookup — the same boundary crossing `nativeCursorFrame` (`CursorBridge.swift`)
// performs for a playback cursor, via `Score.translateCursorForHiddenStaves`. Every step reuses one of these
// two existing `Score` helpers; nothing here re-derives the hidden-staff renumbering rule a third way.

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeEditingHitTest(...)` call site.
///
/// `xMm`/`yMm` are a tap in document millimetres (the unit the Kotlin overlay works in); converted to
/// typographic points the same way every other bridge does (`72.0 / 25.4`). `activeVoice` is threaded straight
/// into `LayoutDocument.editingHitTest(at:activeVoice:)` — see that method's doc comment for the hit-test
/// policy (ladder, slop rescue, on-staff gate, voice preference).
///
/// `optionsBytes` is a `LayoutOptionsWire` payload — the exact same blob `nativeComputeLayout` /
/// `nativeNearestCursor` already receive. Only `hiddenStaffAddresses` is read here; the other fields are
/// ignored, and re-addressing the hit past them reuses `Score.engineCursorForFilteredTap` (wrapping the item in
/// a throwaway `ScoreCursor.item` and unwrapping the result) rather than writing a second implementation of
/// that rule.
///
/// Returns an empty `Data` when the score handle is unknown, the layout document is not cached, the options
/// blob fails to decode, or the tap hit no selectable item. On a hit, returns the `ScoreItemIDCodec` encoding
/// of the item — full-score-addressed for `.note`/`.rest`, per `engineCursorForFilteredTap`'s own switch.
///
/// **Exception**: a `.tuplet` hit is returned with its **filtered** staff address unchanged.
/// `engineCursorForFilteredTap` (`Score+FilteredTapCursor.swift`) passes `.tuplet` (and `.clef`, which
/// `editingHitTest` never returns) through its switch without re-addressing — a pre-existing gap in that
/// shared helper, not something introduced here. With a hidden staff ahead of a tuplet's own staff in the
/// same part, a caller that feeds this straight into an edit intent targeting `TupletID.staff` would hit the
/// wrong staff. Every OTHER caller in this file is unaffected: `nativeEditingCaretFrame` and
/// `nativeEncodeDrawProgram` translate back into filtered addressing before use, so a `.tuplet` id that never
/// left filtered addressing in the first place round-trips through them correctly regardless.
///
/// Not `@available`-annotated: the swift-java jextract `@_cdecl` wrapper that calls this is generated without
/// one, so the entry point must compile at the package's macOS 14 / iOS 17 baseline. The macOS 15 requirement
/// of `editingHitTest` is satisfied with an `if #available` guard below (always true on Android's Swift
/// runtime) — mirrors `nativeNearestCursor`'s own guard.
public func nativeEditingHitTest(
    scoreHandle: Int64,
    xMm: Double,
    yMm: Double,
    activeVoice: Int32,
    optionsBytes: Data,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let document = LayoutDocumentCache.value(for: scoreHandle)
    else { return Data() }

    let hiddenStaves: Set<StaffAddress>
    do {
        hiddenStaves = try LayoutOptionsCodec.decode(optionsBytes).hiddenStaffAddresses
    } catch {
        return Data()
    }

    // mm → document points (inverse of the frame bridges' `pt * 25.4 / 72.0`).
    let mmToPt = 72.0 / 25.4
    let point = CGPoint(x: CGFloat(xMm * mmToPt), y: CGFloat(yMm * mmToPt))

    guard #available(macOS 15.0, iOS 16.0, *) else { return Data() }
    guard let filteredItem = document.editingHitTest(at: point, activeVoice: Int(activeVoice)) else {
        return Data()
    }

    guard case let .item(fullItem) = score.engineCursorForFilteredTap(
        .item(filteredItem), hiddenStaves: hiddenStaves,
    ) else {
        // Unreachable in practice: `engineCursorForFilteredTap` always returns `.item` for an `.item` input
        // (it only ever substitutes a `.beat` cursor for playback-cursor translation, which is a different
        // helper). Kept as a guard, not a force-unwrap, so a future change to that helper fails safe here
        // instead of trapping.
        return Data()
    }

    return ScoreItemIDCodec.encode(fullItem)
}

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeEditingCaretFrame(...)` call
/// site. `itemBytes` is a `ScoreItemIDCodec` payload, full-score-addressed — the same value
/// `nativeEditingHitTest` returns and a host keeps as "the selected item" for edit intents. Re-addressed into
/// the cached (filtered) document's own addressing via `Score.translateCursorForHiddenStaves` (wrapped in a
/// throwaway `ScoreCursor.item`) before the geometry lookup, mirroring `nativeCursorFrame`'s own translate
/// step for a playback cursor.
///
/// `minimumWidthMm` floors a zero-width frame (converted to points before being handed to
/// `LayoutDocument.editingCaretRect(for:in:minimumWidth:)`); pass 0 for no floor.
///
/// Returns an empty `Data` when the score handle is unknown, the layout document is not cached, the item bytes
/// fail to decode, or the item doesn't resolve to a laid-out frame — e.g. a stale ID right after an edit
/// reflows the document. On success, returns the `EditCaretFrameCodec` encoding of the rect (already
/// point → millimetre converted, `25.4 / 72.0`).
public func nativeEditingCaretFrame(
    scoreHandle: Int64,
    itemBytes: Data,
    minimumWidthMm: Double,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }

    let item: ScoreItemID
    do {
        item = try ScoreItemIDCodec.decode(itemBytes)
    } catch {
        return Data()
    }

    guard case let .item(filteredItem) = score.translateCursorForHiddenStaves(
        .item(item), hiddenStaves: entry.hiddenStaves,
    ) else {
        // A `.beat` fallback means `item`'s staff is hidden — there is no laid-out frame for it to caret
        // against (a host cannot have selected it in the first place, since `nativeEditingHitTest` only ever
        // hits items the filtered document actually renders). Refuse rather than resolve against the wrong
        // staff.
        return Data()
    }

    let mmToPt = 72.0 / 25.4
    let ptToMM = 25.4 / 72.0
    guard let rect = entry.document.editingCaretRect(
        for: filteredItem, in: entry.filteredScore, minimumWidth: CGFloat(minimumWidthMm * mmToPt),
    ) else { return Data() }

    return EditCaretFrameCodec.encode(
        xMm: Double(rect.minX) * ptToMM,
        yMm: Double(rect.minY) * ptToMM,
        widthMm: Double(rect.width) * ptToMM,
        heightMm: Double(rect.height) * ptToMM,
    )
}

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeEncodeDrawProgram(...)` call
/// site. Re-encodes the score's already-cached layout with `selectionBytes` tinted — never a relayout: this
/// reads `LayoutDocumentCache.entry(for:)` and re-encodes what it finds. If the cache is empty (no prior
/// `nativeComputeLayout` for this handle) it returns an empty `Data`; the Kotlin side is expected to have
/// called `nativeComputeLayout` first. A silent relayout here would be invisible except as jank — the whole
/// reason this entry point exists is so a selection change repaints without paying for `LayoutEngine.layout`
/// again.
///
/// `selectionBytes` is a `SelectionTintCodec` payload: a packed ARGB color plus a set of
/// full-score-addressed `ScoreItemID`s (the same addressing `nativeEditingHitTest` returns and a host
/// accumulates as its multi-select state). Each id is re-addressed into the cached document's filtered
/// addressing via `Score.translateCursorForHiddenStaves` (an id that lands on a hidden staff is dropped — it
/// cannot correspond to anything the filtered document renders), then expanded with
/// `SelectionExpansion.expand(_:in:)` so a tuplet selection lights up every member note/rest its bracket
/// spans. `LayoutBridge.buildCommands(layout:tint:)` itself does no expansion — this is the one place that
/// must call `SelectionExpansion` before handing IDs to the encoder, or a tuplet selection would tint only its
/// bracket.
///
/// Reproduces `nativeComputeLayout`'s own page assembly exactly, mode for mode: `LayoutDocumentCache.Entry`
/// carries the `LayoutOptionsWire` and `pageWidthMM`/`pageHeightMM` `nativeComputeLayout` was called with
/// (`JNISymbols.swift`), so `LayoutBridge.encodePages(document:options:pageWidthMM:pageHeightMM:tint:)` — the
/// same function `computeWithDocument` itself calls with `tint: nil` — can rebuild the identical page count
/// and per-page dimensions this handle's layout was last computed with, just with `tint` applied. An empty
/// selection therefore reproduces `nativeComputeLayout`'s bytes exactly in **every** layout mode, not only
/// the one (`.horizontal`) whose page size happens to be recoverable from `document.size` alone. `.page`
/// mode's multi-page split, in particular, re-derives from `document.systems` via `LayoutPaginator` — a
/// geometry-only cut, not a second `LayoutEngine.layout` pass — so it is real re-encode work, not a
/// relayout.
///
/// Returns an empty `Data` when the score handle is unknown, the layout is not cached, or `selectionBytes`
/// fails to decode.
public func nativeEncodeDrawProgram(
    scoreHandle: Int64,
    selectionBytes: Data,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }

    let decoded: (argb: UInt32, ids: Set<ScoreItemID>)
    do {
        decoded = try SelectionTintCodec.decode(selectionBytes)
    } catch {
        return Data()
    }

    var expandedIDs: Set<ScoreItemID> = []
    for id in decoded.ids {
        guard case let .item(filtered) = score.translateCursorForHiddenStaves(
            .item(id), hiddenStaves: entry.hiddenStaves,
        ) else { continue }
        expandedIDs.formUnion(SelectionExpansion.expand(filtered, in: entry.filteredScore))
    }

    let tint: (argb: UInt32, ids: Set<ScoreItemID>)? = expandedIDs.isEmpty
        ? nil
        : (argb: decoded.argb, ids: expandedIDs)

    let pages = LayoutBridge.encodePages(
        document: entry.document, options: entry.options,
        pageWidthMM: entry.pageWidthMM, pageHeightMM: entry.pageHeightMM,
        tint: tint,
    )
    return DrawProgramCodec.encode(pages: pages)
}
