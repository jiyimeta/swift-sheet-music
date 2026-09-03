import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
import Wirelet

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`,
    /// clashing with SheetMusicLayout's stub. Anchor to the Layout definition.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// Singleton tables — one per Swift type. Lifetimes are explicit; Kotlin
/// must release every handle it gets, or the score will leak until process
/// exit.
let scoreTable = HandleTable<Score>()

// MARK: - Score lifecycle (swift-java entry points)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeLoadScore(...)` call site. Returns 0 on parse
/// failure or empty input.
public func nativeLoadScore(bytes: Data) -> Int64 {
    guard !bytes.isEmpty else { return 0 }
    do {
        let score = try ScoreBridge.loadScore(bytes: bytes)
        return scoreTable.insert(score)
    } catch {
        return 0
    }
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeReleaseScore(...)` call site. Releases the score
/// handle, its associated layout document cache entry, and — symmetric with
/// those two — any edit session still mirroring it (`EditSessionBridge.swift`).
/// A host that tears down a Reader with an edit session open (back-press,
/// activity destruction, crash recovery) is not guaranteed to call
/// `nativeEndEditSession` first, and without this the session (a full mirror
/// `Score` plus its undo stack) would be retained until process exit, unreachable
/// once `HandleTable`'s monotonic handles move past it.
public func nativeReleaseScore(handle: Int64) {
    scoreTable.release(handle)
    LayoutDocumentCache.release(handle)
    nativeEndEditSession(scoreHandle: handle)
}

// MARK: - Score metadata (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeScoreMetadata(...)` call site. Returns an empty
/// `Data` when the score handle is unknown. The wire format is
/// `i32 titleByteLen + UTF-8 + i32 composerByteLen + UTF-8` per
/// `ScoreMetadataWire`'s @WireFormat encoding.
public func nativeScoreMetadata(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return ScoreMetadataWire(
        title: score.metaTags["workTitle"] ?? "",
        composer: score.metaTags["composer"] ?? "",
    ).encodeToData()
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeOpeningQuarterBpm(...)` call site. Returns the score's
/// opening quarter-note BPM (the tempo governing the start), or MuseScore's
/// 120 default when the handle is unknown. The Android Reader multiplies this
/// by the playback rate to render the "♩ = N" tempo readout.
public func nativeOpeningQuarterBpm(scoreHandle: Int64) -> Double {
    guard let score = scoreTable.value(for: scoreHandle) else { return 120 }
    return score.openingQuarterBpm
}

// MARK: - Parts/staves descriptor (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativePartsStaves(...)` call site. Returns the parts/staves
/// descriptor (names + per-staff default clef) for the inspector's Parts section.
/// Empty `Data` when the handle is unknown.
public func nativePartsStaves(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return PartsStavesWire(score: score).encodeToData()
}

// MARK: - Font metrics (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeInstallSMuFLMetrics(...)` call site. Returns
/// `true` on success, `false` if the byte payload is empty or fails to
/// decode.
///
/// The name kept its `SMuFL` since v3, when the table measured Bravura
/// alone; v4 carries the text face too. Renaming a JNI entry point buys a
/// tidier symbol and costs every host a source break, so the accurate name
/// lives on the type (`FontMetricsTable`) instead.
public func nativeInstallSMuFLMetrics(bytes: Data) -> Bool {
    guard !bytes.isEmpty else { return false }
    do {
        let table = try FontMetricsTable.decode(bytes)
        FontMetrics.provider = makeFontMetricsTableProvider(table: table)
        return true
    } catch {
        return false
    }
}

// MARK: - Layout (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeComputeLayout(...)` call site. Returns an empty
/// `Data` when the score handle is unknown or the options blob fails to
/// decode; otherwise stores the laid-out document in `LayoutDocumentCache`
/// and returns the encoded draw-program payload. `optionsBlob` is a
/// `LayoutOptionsWire` payload carrying the layout mode, staff size, break /
/// multi-measure-rest / invisible-element toggles, hidden staves, and clef
/// overrides selected in the Android Reader's display inspector.
public func nativeComputeLayout(
    scoreHandle: Int64,
    pageWidthMM: Double,
    pageHeightMM: Double,
    optionsBlob: Data,
) -> Data {
    // Read the generation BEFORE the score, so an edit landing between the two is counted rather than missed —
    // see `LayoutDocumentCache.scoreGeneration(for:)`. This function does not take the edit lock (nothing that
    // lays out does), so an edit can replace the score at any point below; the stamp is how the store at the end
    // finds out.
    let generation = LayoutDocumentCache.scoreGeneration(for: scoreHandle)
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    let optionsWire: LayoutOptionsWire
    do {
        optionsWire = try LayoutOptionsCodec.decode(optionsBlob)
    } catch {
        return Data()
    }
    let result = LayoutBridge.computeWithDocument(
        score: score,
        pageWidthMM: pageWidthMM,
        pageHeightMM: pageHeightMM,
        options: optionsWire,
    )
    // A refused store leaves the cache empty rather than stale, and the encoded program is still returned: the
    // caller asked for a drawing of the score as it was, and the edit that overtook it has already asked for the
    // recompute that supersedes it. What must not happen is `nativeEditingHitTest` resolving a tap against this
    // document afterwards.
    LayoutDocumentCache.store(
        handle: scoreHandle,
        document: result.document,
        filteredScore: result.filteredScore,
        hiddenStaves: optionsWire.hiddenStaffAddresses,
        options: optionsWire,
        pageWidthMM: pageWidthMM,
        pageHeightMM: pageHeightMM,
        computedFromGeneration: generation,
    )
    return result.encoded
}

// MARK: - Page boundaries (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativePageBreaks(...)` call site. Returns page-boundary
/// document-Y offsets in millimetres for the cached layout of `scoreHandle`,
/// paginated with the same `pageHeightMM` + `optionsBytes` passed to
/// `nativeComputeLayout` so the boundaries match the `.page` draw-program
/// pages exactly.
///
/// Wire format: `i32 count` (big-endian) then `count × f64` big-endian IEEE 754.
/// The sequence is `[0, top1, …, contentBottom]` — one entry per page boundary
/// plus the content bottom (`count == pageCount + 1`). Returns empty `Data`
/// when the handle is unknown, the options blob fails to decode, or
/// `LayoutPaginator` returns no ranges.
public func nativePageBreaks(scoreHandle: Int64, pageHeightMM: Double, optionsBytes: Data) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle) else { return Data() }
    let optionsWire: LayoutOptionsWire
    do {
        optionsWire = try LayoutOptionsCodec.decode(optionsBytes)
    } catch {
        return Data()
    }
    let mmToPt = 72.0 / 25.4
    let pageHeightPt = CGFloat(pageHeightMM * mmToPt)
    let breakPolicy: LayoutBreakPolicy = optionsWire.honorLayoutBreaks == 1 ? .honor : .ignoreAll
    let ranges = LayoutPaginator.paginate(
        systems: document.systems, pageHeight: pageHeightPt, policy: breakPolicy,
    )
    guard !ranges.isEmpty else { return Data() }
    var offsetsMm: [Double] = []
    for (i, range) in ranges.enumerated() {
        let topPt: CGFloat = i == 0
            ? 0
            : document.systems[range.lowerBound - 1].origin.y
            + document.systems[range.lowerBound - 1].size.height
        offsetsMm.append(Double(topPt) / mmToPt)
    }
    let lastSystem = document.systems[document.systems.count - 1]
    offsetsMm.append(Double(lastSystem.origin.y + lastSystem.size.height) / mmToPt)
    return PageBreaksWire.encode(offsetsMm)
}
