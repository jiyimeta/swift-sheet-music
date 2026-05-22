import Foundation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicWireFormat

/// Singleton tables — one per Swift type. Lifetimes are explicit; Kotlin
/// must release every handle it gets, or the score will leak until process
/// exit. Declared outside `#if os(Android)` so host-platform swift-java
/// entry points (e.g. `nativeRenderMidi`) can resolve handles without
/// duplicating the table.
let scoreTable = HandleTable<Score>()

// MARK: - Wire format payloads

@WireFormat
struct ScoreMetadataWire {
    var title: String
    var composer: String
}

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
/// handle and its associated layout document cache entry.
public func nativeReleaseScore(handle: Int64) {
    scoreTable.release(handle)
    LayoutDocumentCache.release(handle)
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

// MARK: - SMuFL font metrics (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeInstallSMuFLMetrics(...)` call site. Returns
/// `true` on success, `false` if the byte payload is empty or fails to
/// decode.
public func nativeInstallSMuFLMetrics(bytes: Data) -> Bool {
    guard !bytes.isEmpty else { return false }
    do {
        let table = try SMuFLMetricsTable.decode(bytes)
        FontMetrics.provider = makeSMuFLMetricsTableProvider(table: table)
        return true
    } catch {
        return false
    }
}

// MARK: - Layout (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeComputeLayout(...)` call site. Returns an empty
/// `Data` when the score handle is unknown; otherwise stores the laid-out
/// document in `LayoutDocumentCache` and returns the encoded draw-program
/// payload.
public func nativeComputeLayout(
    scoreHandle: Int64,
    pageWidthMM: Double,
    pageHeightMM: Double,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    let result = LayoutBridge.computeWithDocument(
        score: score,
        pageWidthMM: pageWidthMM,
        pageHeightMM: pageHeightMM,
    )
    LayoutDocumentCache.store(handle: scoreHandle, document: result.document)
    return result.encoded
}
