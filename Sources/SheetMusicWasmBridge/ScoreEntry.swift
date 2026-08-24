import JavaScriptKit
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation

/// Handle table for the wasm bridge. Mirrors `SheetMusicAndroidJNI`'s
/// `scoreTable`: the host owns every handle it is given and must release it, or
/// the score leaks until the page is closed.
let scoreTable = HandleTable<Score>()

/// What the host shows in a title bar or a document list.
///
/// Android returns this as three separate calls (`nativeScoreMetadata`,
/// `nativePartsStaves`, `nativeOpeningQuarterBpm`), each with its own wire
/// payload, because the Wirelet Gradle plugin generates matching Kotlin
/// decoders. There is no such generator for JavaScript, so the wasm surface uses
/// a `@JS struct` and lets BridgeJS lower the fields — the host never sees a
/// wire format, and one call replaces three.
@JS public struct ScoreMetadata {
    public var title: String
    public var composer: String
    public var partCount: Int
    public var staffCount: Int
    /// The tempo governing the start, in quarter-note BPM. MuseScore's 120
    /// default when the score sets none.
    public var openingQuarterBpm: Double

    /// Spelled out rather than left to the memberwise default, which would be
    /// `internal`: BridgeJS generates a `@_transparent` lowering function that
    /// calls this initializer, and a `@_transparent` body cannot reference an
    /// internal declaration.
    public init(
        title: String,
        composer: String,
        partCount: Int,
        staffCount: Int,
        openingQuarterBpm: Double,
    ) {
        self.title = title
        self.composer = composer
        self.partCount = partCount
        self.staffCount = staffCount
        self.openingQuarterBpm = openingQuarterBpm
    }
}

/// Parse `bytes` — `.mscx`, `.mscz`, `.musicxml`, `.mxl` or `.mid`, sniffed from
/// the leading bytes — and retain the result. Returns `0` on an empty payload or
/// a parse failure.
///
/// Android: `nativeLoadScore`.
///
/// Handles are `Int64` in `HandleTable`, but they are allocated monotonically
/// from 1, so an i32 cannot run out inside one page. Narrowing here keeps the
/// JavaScript side off `bigint` for a value it only ever passes back in.
@JS public func loadScore(bytes: JSUint8Array) -> Int {
    let data = bytes.bridgedData
    guard !data.isEmpty else { return 0 }
    do {
        return try Int(scoreTable.insert(ScoreBridge.loadScore(bytes: data)))
    } catch {
        return 0
    }
}

/// Release the score behind `handle` together with everything cached against
/// it — the laid-out document and the playback clock.
///
/// Every cache keyed by a handle has to be listed here. Handles are allocated
/// monotonically so one is never reused inside a page, but a leak keeps a whole
/// engraved document and an unrolled timeline alive until the tab closes.
///
/// Android: `nativeReleaseScore`, which also tears down an edit session. Editing
/// has not reached the wasm surface yet; when it does this gains a fourth call.
@JS public func releaseScore(handle: Int) {
    scoreTable.release(Int64(handle))
    LayoutDocumentCache.release(Int64(handle))
    PlaybackClockCache.release(Int64(handle))
}

/// Metadata for `handle`, or `nil` when the handle is unknown or released.
///
/// Android: `nativeScoreMetadata` + `nativePartsStaves` + `nativeOpeningQuarterBpm`.
@JS public func scoreMetadata(handle: Int) -> ScoreMetadata? {
    guard let score = scoreTable.value(for: Int64(handle)) else { return nil }
    return ScoreMetadata(
        title: score.metaTags["workTitle"] ?? "",
        composer: score.metaTags["composer"] ?? "",
        partCount: score.parts.count,
        staffCount: score.parts.reduce(0) { $0 + $1.staves.count },
        openingQuarterBpm: score.openingQuarterBpm,
    )
}

/// The digest the host compares against its own copy, as a decimal string.
/// Empty for an unknown handle.
///
/// Android: `nativeScoreFingerprint`, which returns the `Int64` directly.
/// `Score.stableFingerprint` is FNV-1a with fixed constants and no per-process
/// seed, so an Apple host and this one produce the same number for the same
/// score — which is what the parity test in `Web/sheet-music-web` compares, and
/// why the whole 64 bits have to survive. `Int` is 32 bits on wasm32, so
/// returning one would either trap or halve the digest; `Int64` would lower to a
/// `bigint` that a JSON fixture cannot carry. Same reasoning as
/// `engineVersionStamp`.
@JS public func scoreFingerprint(handle: Int) -> String {
    guard let score = scoreTable.value(for: Int64(handle)) else { return "" }
    return String(score.stableFingerprint)
}
