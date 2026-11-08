import Foundation
import SheetMusicAudioCore
import SheetMusicAudioSignalsmith
import SheetMusicAudioSwiftySynthCore

// The recordings Kotlin mixes onto the score synth (`AndroidPlaybackEngine.setRecordingTracks` / `setAlignment`): the
// tracks and the alignment are staged one primitive call at a time and committed in one, so neither crosses JNI as a
// wire format of its own. The render is `SynthRenderJNI.swift`'s `nativeRenderMix`.
//
// Kotlin makes every call for a synth from under its driver's lock, so the staging of one handle is never written by
// two threads at once; the table lock below covers the dictionary only.

/// What Kotlin staged for one score synth, and what it last committed.
final class RecordingStaging: @unchecked Sendable {
    var stagedTracks: [RecordingDeck.Track] = []
    var deck = RecordingDeck()
    var spans: [PlaybackTimeWarp.Span] = []
    var segments: [RecordingSegment] = []
    var trackSegments: [String: [RecordingSegment]] = [:]
}

enum RecordingBridge {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stagings: [Int64: RecordingStaging] = [:]

    /// The staging for the synth behind `handle`, made on first use.
    static func staging(_ handle: Int64) -> RecordingStaging {
        lock.lock()
        defer { lock.unlock() }
        if let staging = stagings[handle] { return staging }
        let staging = RecordingStaging()
        stagings[handle] = staging
        return staging
    }

    /// Drops the staging of a released synth, so a synth later made at the same address starts clean.
    static func forget(_ handle: Int64) {
        lock.lock()
        defer { lock.unlock() }
        stagings[handle] = nil
    }

    /// Maps the staged tracks and hands them to the synth. -1, the playing tracks left as they were, when a file cannot
    /// be mapped; -2 for an unknown handle.
    static func commitTracks(handle: Int64, soloing: Bool, readerTransposeSemitones: Int) -> Int32 {
        guard let synth = SynthBridge.synth(handle) else { return -2 }
        let staging = staging(handle)
        do {
            try staging.deck.replace(with: staging.stagedTracks)
        } catch {
            return -1
        }
        synth.setRecordingTracks(
            staging.deck.renders(soloing: soloing, readerTransposeSemitones: readerTransposeSemitones),
        )
        return 0
    }

    /// Hands the staged alignment to the synth. -1 for a warp `PlaybackTimeWarp` refuses (nothing changes); -2 for an
    /// unknown handle.
    static func commitAlignment(handle: Int64) -> Int32 {
        guard let synth = SynthBridge.synth(handle) else { return -2 }
        let staging = staging(handle)
        let warp: PlaybackTimeWarp?
        do {
            warp = staging.spans.isEmpty ? nil : try PlaybackTimeWarp(spans: staging.spans)
        } catch {
            return -1
        }
        synth.setPlaybackAlignment(warp: warp, segments: staging.segments, trackSegments: staging.trackSegments)
        return 0
    }
}

// MARK: - swift-java entry points: recordings

/// Empties the staged track list of the synth behind `handle`.
public func nativeSynthRecordingsClear(handle: Int64) {
    RecordingBridge.staging(handle).stagedTracks = []
}

/// Stages one recording strip: its PCM cache file (`RecordingPCMCacheFormat`), where it starts in the reference time,
/// its own transposition and its strip's mix.
public func nativeSynthRecordingsStage(
    handle: Int64, id: String, pcmPath: String, offsetSeconds: Double, transposeSemitones: Int32, volume: Double,
    muted: Bool, soloed: Bool,
) {
    RecordingBridge.staging(handle).stagedTracks.append(RecordingDeck.Track(
        id: id, pcmPath: pcmPath, offsetSeconds: offsetSeconds, transposeSemitones: Int(transposeSemitones),
        volume: Float(volume), isMuted: muted, isSoloed: soloed,
    ))
}

/// Commits the staged strips: 0, or -1 — the playing tracks left as they were — when a file cannot be mapped. `soloing`
/// is whether the solo bus is engaged, by an instrument strip or a recording; `readerTransposeSemitones` the reader's
/// transposition, added to each track's own.
public func nativeSynthRecordingsCommit(handle: Int64, soloing: Bool, readerTransposeSemitones: Int32) -> Int32 {
    RecordingBridge.commitTracks(
        handle: handle, soloing: soloing, readerTransposeSemitones: Int(readerTransposeSemitones),
    )
}

/// Empties the staged alignment of the synth behind `handle`.
public func nativeSynthAlignmentClear(handle: Int64) {
    let staging = RecordingBridge.staging(handle)
    staging.spans = []
    staging.segments = []
    staging.trackSegments = [:]
}

/// Stages one warp span: transport seconds `start ..< end` last `duration` seconds at 100 %.
public func nativeSynthAlignmentAddSpan(handle: Int64, start: Double, end: Double, duration: Double) {
    RecordingBridge.staging(handle).spans.append(.init(start: start, end: end, duration: duration))
}

/// Stages one segment of the shared table (`trackId` empty) or of track `trackId`'s own.
public func nativeSynthAlignmentAddSegment(
    handle: Int64, trackId: String, sourceStart: Double, sourceEnd: Double, outputStart: Double,
) {
    let staging = RecordingBridge.staging(handle)
    let segment = RecordingSegment(sourceStart: sourceStart, sourceEnd: sourceEnd, outputStart: outputStart)
    if trackId.isEmpty {
        staging.segments.append(segment)
    } else {
        staging.trackSegments[trackId, default: []].append(segment)
    }
}

/// Commits the staged alignment: 0, or -1 for a warp whose spans are invalid or overlap (nothing changes).
public func nativeSynthAlignmentCommit(handle: Int64) -> Int32 {
    RecordingBridge.commitAlignment(handle: handle)
}

/// How long the score waits for a count-in of `seconds` (its metronome SMF's length) into where the sequence is parked
/// — `HostedSynth.countIn(seconds:)`. 0 for an unknown handle.
public func nativeSynthCountInDuration(handle: Int64, seconds: Double) -> Double {
    SynthBridge.synth(handle)?.countIn(seconds: seconds).duration ?? 0
}

/// The speed the metronome counts that count-in at under a warp, or 0 when there is none and it keeps the user's rate.
public func nativeSynthCountInSpeed(handle: Int64, seconds: Double) -> Double {
    SynthBridge.synth(handle)?.countIn(seconds: seconds).speed ?? 0
}

/// Where the attached sequence stands on the warped clock — the recording's seconds at 100 %.
public func nativeSynthCurrentOutputSeconds(handle: Int64) -> Double {
    guard let synth = SynthBridge.synth(handle) else { return 0 }
    return synth.outputSeconds(atTransport: synth.currentTransportSeconds)
}

/// The warped second of the attached sequence's `tick`.
public func nativeSynthOutputSecondsAtTick(handle: Int64, tick: Int64) -> Double {
    guard let synth = SynthBridge.synth(handle) else { return 0 }
    return synth.outputSeconds(atTransport: synth.transportSeconds(atTick: Int(clamping: tick)))
}

/// The attached sequence's tick at warped second `seconds`.
public func nativeSynthTickAtOutputSeconds(handle: Int64, seconds: Double) -> Int64 {
    guard let synth = SynthBridge.synth(handle) else { return 0 }
    return Int64(synth.tick(atTransportSeconds: synth.transportSeconds(atOutput: seconds)))
}

/// Reads the recordings' next pages in from where the transport is and, for `loopStartTick` ≥ 0, from the loop's start.
public func nativeSynthRecordingsPrefetch(handle: Int64, loopStartTick: Int64) {
    guard let synth = SynthBridge.synth(handle) else { return }
    let loopStart = loopStartTick >= 0 ? synth.transportSeconds(atTick: Int(clamping: loopStartTick)) : nil
    synth.prefetchRecordings(loopStartTransportSeconds: loopStart)
}

/// Reads recordings through Signalsmith Stretch on the synth behind `handle`, so they keep their pitch away from 100 %
/// and can be transposed. Kotlin calls it once for the score synth.
public func nativeSynthEnableRecordingStretch(handle: Int64) {
    SynthBridge.synth(handle)?.setRecordingStretcherFactory(.signalsmith)
}

// MARK: - swift-java entry points: the PCM cache

/// The path of a valid cache file for `cacheKey` at `sampleRate` in `directory`, or "" when there is none and the
/// recording has to be decoded.
public func nativeRecordingCacheExisting(directory: String, cacheKey: String, sampleRate: Double) -> String {
    RecordingPCMCacheWriter.existingFile(directory: directory, cacheKey: cacheKey, sampleRate: sampleRate) ?? ""
}

/// Starts a cache file for `cacheKey` at `sampleRate` in `directory`; 0 when the sample rate is refused or the file
/// cannot be created. Append with `RecordingPcmNative.nativeAppend`, then finish or cancel.
public func nativeRecordingCacheWriterOpen(directory: String, cacheKey: String, sampleRate: Double) -> Int64 {
    guard let writer = try? RecordingPCMCacheWriter(directory: directory, cacheKey: cacheKey, sampleRate: sampleRate)
    else { return 0 }
    return SynthBridge.retain(writer)
}

/// Writes the header, moves the file into place and releases the writer: the file's path, or "" on failure (no
/// frames, a write error), the temporary file then removed. The handle must not be used again.
public func nativeRecordingCacheWriterFinish(handle: Int64) -> String {
    guard let writer = SynthBridge.object(RecordingPCMCacheWriter.self, handle) else { return "" }
    defer { SynthBridge.release(RecordingPCMCacheWriter.self, handle) }
    return (try? writer.finish()) ?? ""
}

/// Abandons the file and releases the writer. The handle must not be used again.
public func nativeRecordingCacheWriterCancel(handle: Int64) {
    SynthBridge.object(RecordingPCMCacheWriter.self, handle)?.cancel()
    SynthBridge.release(RecordingPCMCacheWriter.self, handle)
}

/// Appends `frameCount` frames of `channels` (1 or 2) interleaved Int16 samples, for a host test. Kotlin appends
/// through `SynthRenderJNI.swift`'s `nativeAppend`. 0, or -1 when the write failed (the writer is then cancelled).
func recordingCacheWriterAppend(
    handle: Int64, samples: UnsafePointer<Int16>, frameCount: Int, channels: Int,
) -> Int32 {
    guard let writer = SynthBridge.object(RecordingPCMCacheWriter.self, handle), frameCount >= 0 else { return -1 }
    do {
        if channels == 1 {
            try writer.append(mono: samples, frameCount: frameCount)
        } else {
            try writer.append(interleavedStereo: samples, frameCount: frameCount)
        }
        return 0
    } catch {
        return -1
    }
}
