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

/// One rehearsal mark as a browser host can use it: text for display, the
/// measure it belongs to, and the player-clock seek target.
///
/// `playerSeconds` is `-1` when the mark's cursor does not resolve on the
/// player clock — the same sentinel `playerSecondsAtPoint` uses, and for the
/// same reason: `0` is the top of the score, so it cannot mean "nowhere".
/// The mark is still listed. A rehearsal-mark list is a navigation index, and
/// dropping an entry because its seek target failed shows a reader a list that
/// skips a letter with nothing to say why. A host disables seeking on it.
@JS public struct RehearsalMarkInfo {
    public var text: String
    public var measureIndex: Int
    public var playerSeconds: Double

    public init(text: String, measureIndex: Int, playerSeconds: Double) {
        self.text = text
        self.measureIndex = measureIndex
        self.playerSeconds = playerSeconds
    }
}

/// One flattened staff descriptor. `PartsStavesWire` is part -> staves, but a
/// JavaScript host indexes the staff list directly and carries the owning part
/// identity on each item.
@JS public struct StaffDescriptor {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var partName: String
    public var isPartVisibleInScore: Bool
    public var defaultClefRawType: String
    public var trackName: String
    public var instrumentLongName: String
    public var groupRawValue: String

    public init(
        partIndex: Int,
        staffIndexInPart: Int,
        partName: String,
        isPartVisibleInScore: Bool,
        defaultClefRawType: String,
        trackName: String,
        instrumentLongName: String,
        groupRawValue: String,
    ) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.partName = partName
        self.isPartVisibleInScore = isPartVisibleInScore
        self.defaultClefRawType = defaultClefRawType
        self.trackName = trackName
        self.instrumentLongName = instrumentLongName
        self.groupRawValue = groupRawValue
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
/// it — the laid-out document, the playback clock and any open edit session.
///
/// Every cache keyed by a handle has to be listed here. Handles are allocated
/// monotonically so one is never reused inside a page, but a leak keeps a whole
/// engraved document and an unrolled timeline alive until the tab closes.
///
/// Android: `nativeReleaseScore`, which also tears down an edit session.
@JS public func releaseScore(handle: Int) {
    scoreTable.release(Int64(handle))
    LayoutDocumentCache.release(Int64(handle))
    PlaybackClockCache.release(Int64(handle))
    releaseEditSession(handle: Int64(handle))
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

/// How many rehearsal marks `handle` has. `0` for an unknown handle.
///
/// Paired with `rehearsalMark(handle:index:)` for the same reason the mixer
/// surface is count + index: this package has not established array-of-`@JS
/// struct` lowering as a browser ABI.
@JS public func rehearsalMarkCount(handle: Int) -> Int {
    guard let score = scoreTable.value(for: Int64(handle)) else { return 0 }
    return rehearsalMarkInfos(for: score, handle: Int64(handle)).count
}

/// The rehearsal mark at `index`, or `nil` when the handle is unknown or the
/// index is out of range. A mark whose cursor does not resolve is still
/// returned, carrying `-1` seconds — see `RehearsalMarkInfo`.
@JS public func rehearsalMark(handle: Int, index: Int) -> RehearsalMarkInfo? {
    guard let score = scoreTable.value(for: Int64(handle)) else { return nil }
    let infos = rehearsalMarkInfos(for: score, handle: Int64(handle))
    guard index >= 0, index < infos.count else { return nil }
    return infos[index]
}

/// How many flattened staff descriptors `handle` has. `0` for an unknown
/// handle.
@JS public func staffDescriptorCount(handle: Int) -> Int {
    guard let score = scoreTable.value(for: Int64(handle)) else { return 0 }
    return PartsStavesWire(score: score).parts.reduce(0) { $0 + $1.staves.count }
}

/// The flattened staff descriptor at `index`, or `nil` when the handle is
/// unknown or the index is out of range.
@JS public func staffDescriptor(handle: Int, index: Int) -> StaffDescriptor? {
    guard let score = scoreTable.value(for: Int64(handle)), index >= 0 else { return nil }
    let parts = PartsStavesWire(score: score).parts
    var flatIndex = 0
    for (partIndex, part) in parts.enumerated() {
        for (staffIndex, staff) in part.staves.enumerated() {
            if flatIndex == index {
                let scorePart = score.parts[partIndex]
                return StaffDescriptor(
                    partIndex: partIndex,
                    staffIndexInPart: staffIndex,
                    partName: part.name,
                    isPartVisibleInScore: part.isVisibleInScore != 0,
                    defaultClefRawType: staff.defaultClefRawType,
                    trackName: scorePart.trackName ?? "",
                    instrumentLongName: scorePart.instrument.longName ?? "",
                    groupRawValue: scorePart.staves[staffIndex].group,
                )
            }
            flatIndex += 1
        }
    }
    return nil
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

/// Every mark the score has, in score order, with `-1` seconds for any whose
/// cursor does not resolve. Deliberately not `compactMap`: the count has to
/// agree with the score's own, or a host renders a rehearsal index missing a
/// letter and has no way to know one was dropped.
private func rehearsalMarkInfos(for score: Score, handle: Int64) -> [RehearsalMarkInfo] {
    let clock = PlaybackClockCache.clock(for: handle, score: score)
    return score.rehearsalMarks().map { mark in
        RehearsalMarkInfo(
            text: mark.text,
            measureIndex: mark.cursor.measureIndex,
            playerSeconds: clock.playerSeconds(atCursor: mark.cursor) ?? -1,
        )
    }
}
