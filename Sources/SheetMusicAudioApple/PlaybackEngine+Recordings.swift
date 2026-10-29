import Foundation
import SheetMusicAudioCore

/// One recording on the engine's mixer: a decoded PCM cache file (`RecordingPCMCache`) placed against the reference
/// recording's time, with its strip's mix. A recording strip sits on the same solo bus as the instrument strips
/// (`PlaybackEngine.setRecordingMix(id:volume:isMuted:isSoloed:)`).
public struct RecordingTrack: Sendable {
    /// Unique in a track list and stable across `setRecordingTracks(_:)` calls: a track whose id was already playing
    /// carries on from where it is.
    public let id: String
    /// The PCM cache file to play, mapped by `setRecordingTracks(_:)`.
    public let pcmFile: URL
    /// Seconds into the reference recording's time at which this file starts.
    public var offsetSeconds: TimeInterval
    /// The track's own transposition, on top of the reader's (`PlaybackEngine.setTranspose(semitones:)`).
    public var transposeSemitones: Int
    /// Linear gain in `0...1`, as an instrument strip's (`MixerChannel.volume`).
    public var volume: Float
    public var isMuted: Bool
    public var isSoloed: Bool

    public init(
        id: String, pcmFile: URL, offsetSeconds: TimeInterval = 0, transposeSemitones: Int = 0, volume: Float = 1,
        isMuted: Bool = false, isSoloed: Bool = false,
    ) {
        self.id = id
        self.pcmFile = pcmFile
        self.offsetSeconds = offsetSeconds
        self.transposeSemitones = transposeSemitones
        self.volume = volume
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

/// A recording the engine holds: the host's description, kept current by `setRecordingMix`, and its mapped PCM.
struct LoadedRecordingTrack {
    var track: RecordingTrack
    let recording: MappedRecording
}

/// One track as the engine last handed it to the backend, so a mixer pass that resolves to the same tracks can send
/// nothing.
struct RecordingRenderKey: Equatable {
    let id: String
    let recording: ObjectIdentifier
    let offsetSeconds: TimeInterval
    let gain: Float
    let transposeSemitones: Double

    init(_ render: RecordingTrackRender) {
        id = render.id
        recording = ObjectIdentifier(render.recording)
        offsetSeconds = render.offsetSeconds
        gain = render.gain
        transposeSemitones = render.transposeSemitones
    }
}

extension PlaybackEngine {
    // MARK: Tracks and mix

    /// Replaces the recordings mixed with the score, each played at its strip's mix. Callable while playing: a track
    /// whose `id` was already playing carries on from where it is.
    ///
    /// Every file is mapped before anything changes: a file that cannot be (`MappedRecording.Failure`) throws, and the
    /// recordings already playing stay as they were. A soloed track silences every unsoloed instrument strip, so the
    /// instrument strips are re-applied too. On a backend that cannot play recordings
    /// (`SynthBackend.canPlayRecordings`) the tracks are kept and their solos still count, but nothing sounds.
    ///
    /// The tracks belong to the host, not to the score: they survive `prepare(score:)` and `teardown()`, as the
    /// alignment does (`setAlignment(warp:segments:)`). A host that switches to another score clears both
    /// (`setRecordingTracks([])`, `setAlignment(warp: nil, segments: [])`), or sets the new score's, before it plays.
    public func setRecordingTracks(_ tracks: [RecordingTrack]) throws {
        let loaded = try tracks.map { track in
            try LoadedRecordingTrack(track: track, recording: MappedRecording(pcmFile: track.pcmFile))
        }
        recordings = loaded
        // New mappings: hand them over even if they resolve to what was sent.
        sentRecordingRenders = nil
        applyMixerState()
        prefetchRecordings()
    }

    /// Sets a recording strip's volume (linear, applied clamped to `0...1`), mute and solo, as `setVolume`, `setMuted`
    /// and `setSoloed` set an instrument strip's. Solo is one bus across both kinds: while any instrument strip or
    /// recording is soloed, only the soloed ones sound, and un-soloing all of them gives each its own mute back. The
    /// metronome stays off the bus. No-op for an id not in the track list.
    public func setRecordingMix(id: String, volume: Float, isMuted: Bool, isSoloed: Bool) {
        guard let index = recordings.firstIndex(where: { $0.track.id == id }) else { return }
        recordings[index].track.volume = volume
        recordings[index].track.isMuted = isMuted
        recordings[index].track.isSoloed = isSoloed
        applyMixerState()
    }

    /// The recordings as the backend mixes them: each strip's volume, or 0 when it is muted or another strip is
    /// soloed; the reader's transposition plus the track's own.
    func recordingRenders(soloing: Bool) -> [RecordingTrackRender] {
        recordings.map { loaded in
            let track = loaded.track
            let silenced = track.isMuted || (soloing && !track.isSoloed)
            return RecordingTrackRender(
                id: track.id, recording: loaded.recording, offsetSeconds: track.offsetSeconds,
                gain: silenced ? 0 : max(0, min(1, track.volume)),
                transposeSemitones: Double(transposeSemitones + track.transposeSemitones),
            )
        }
    }

    /// Hands the backend the recordings as they resolve now, unless that is what it already has. The ids are the
    /// host's, so a backend keeps every playing track's position through a change of gain or transposition.
    func pushRecordingTracks(soloing: Bool) {
        let renders = recordingRenders(soloing: soloing)
        let keys = renders.map(RecordingRenderKey.init)
        guard keys != sentRecordingRenders else { return }
        sentRecordingRenders = keys
        backend?.setRecordingTracks(renders)
    }

    // MARK: Alignment

    /// The alignment the transport and the recordings follow: `warp` sets how long each stretch of the transport's
    /// clock lasts (nil = the notated tempo), and `segments` which seconds of the reference recording sound at each
    /// warped second. Callable while playing: it is a table swap on the backend, never a stop, a seek or a reload, and
    /// the new speed applies from its next synthesizer block.
    ///
    /// While one is set (`hasAlignment`), `currentTimeSeconds`, `currentTimeSecondsContinuous` and
    /// `totalTimeSeconds` report warped seconds at 100 % rate — the recording's time, which is what a seek bar under
    /// it shows — and `seek(toTimeSeconds:)` and `skip(by:)` take them. `notatedTimeSecondsContinuous` stays on the
    /// notated timeline, and `notatedSeconds(forReportedSeconds:)` / `reportedSeconds(forNotatedSeconds:)` convert
    /// between the two clocks. `setAlignment(warp: nil, segments: [])` clears it.
    ///
    /// The alignment belongs to the host, not to the score: it survives `prepare(score:)` and `teardown()`, as the
    /// recordings do (`setRecordingTracks(_:)`). A host that switches to another score clears both, or sets the new
    /// score's, before it plays.
    public func setAlignment(warp: PlaybackTimeWarp?, segments: [RecordingSegment]) {
        alignmentWarp = warp
        alignmentSegments = segments
        alignmentSpeedTable = TransportSpeedTable(warp: warp)
        alignmentSchedule = RecordingSchedule(segments: segments)
        backend?.setPlaybackAlignment(warp: warp, segments: segments)
        prefetchRecordings()
    }

    /// Whether the transport follows an alignment: one with a span or a segment is set, on a backend that plays
    /// recordings. Time is then reported on the warped clock (`setAlignment(warp:segments:)`).
    public var hasAlignment: Bool {
        guard backend?.canPlayRecordings == true else { return false }
        return !(alignmentWarp?.spans.isEmpty ?? true) || !alignmentSegments.isEmpty
    }

    // MARK: Reading ahead

    /// Wall-clock seconds of each recording read in ahead of the transport.
    nonisolated static let recordingPrefetchAheadSeconds = 2.0
    /// File seconds read in behind each stretch as well: a stretcher primed at a jump is fed the input before it.
    nonisolated static let recordingPrefetchBehindSeconds = 0.5
    /// Cursor polls (about 30 a second) between read-aheads while playing.
    static let recordingPrefetchTickInterval = 10

    /// Asks for the pages each recording plays over the next couple of seconds to be read in now, so the render thread
    /// does not fault on them (`MappedRecording.prefetch(seconds:)`): from where the transport is, and while a loop is
    /// set also from its start, where the wrap lands. Called on the main actor after a play, a seek, a loop wrap, a new
    /// alignment or track list, and every `recordingPrefetchTickInterval` cursor polls while playing. The position is
    /// the transport's, turned into each track's file seconds by the warp and the segments; nothing of the render
    /// thread's own state is read.
    func prefetchRecordings() {
        recordingPrefetchCountdown = Self.recordingPrefetchTickInterval
        guard let backend, backend.canPlayRecordings, !recordings.isEmpty else { return }
        var origins = [backend.currentPositionSeconds]
        if let loop = transportLoop { origins.append(loop.startSeconds) }
        for loaded in recordings {
            for origin in origins {
                let ranges = Self.recordingPrefetchRanges(
                    transportSeconds: origin, rate: Double(pendingRate), table: alignmentSpeedTable,
                    schedule: alignmentSchedule, offset: loaded.track.offsetSeconds,
                )
                for seconds in ranges {
                    loaded.recording.prefetch(seconds: seconds)
                }
            }
        }
    }

    /// The file seconds a track plays from transport second `transportSeconds` on, `recordingPrefetchAheadSeconds` of
    /// wall-clock time at `rate` (and never fewer warped seconds than that), each stretch widened back by
    /// `recordingPrefetchBehindSeconds` for the history a stretcher is primed with. `table` turns the transport second
    /// into a warped one and `schedule` the warped window into the track's file, at its `offset`.
    nonisolated static func recordingPrefetchRanges(
        transportSeconds: TimeInterval, rate: Double, table: TransportSpeedTable, schedule: RecordingSchedule,
        offset: TimeInterval,
    ) -> [Range<TimeInterval>] {
        let output = table.outputSeconds(atTransport: transportSeconds)
        let speed = rate.isFinite ? max(1, rate) : 1
        let window = schedule.sourceRanges(
            fromOutput: output, to: output + recordingPrefetchAheadSeconds * speed, offset: offset,
        )
        return window.map { max(0, $0.lowerBound - recordingPrefetchBehindSeconds) ..< $0.upperBound }
    }
}
