import Foundation
import SheetMusicAudioCore
import SheetMusicAudioSignalsmith
import SheetMusicAudioSwiftySynthCore
import SheetMusicBridgeCore
import SheetMusicCore

/// One recording on the engine's mixer: a decoded PCM cache file (`RecordingPCMCacheWriter`, filled on Windows by
/// `MediaFoundationAudio.decodeRecordingCache`) placed against the reference recording's time, with its strip's mix —
/// the Apple engine's `RecordingTrack`, under the same name and fields. A recording strip sits on the same solo bus as
/// the instrument strips.
public struct RecordingTrack: Sendable, Equatable {
    /// Unique in a track list and stable across `setRecordingTracks(_:)` calls: a track whose id was already playing
    /// carries on from where it is.
    public let id: String
    /// The PCM cache file to play, mapped by `setRecordingTracks(_:)` and kept mapped for as long as the track keeps
    /// its `id` and this URL.
    public let pcmFile: URL
    /// Seconds into the reference recording's time at which this file starts.
    public var offsetSeconds: TimeInterval
    /// The track's own transposition, on top of the reader's (`setTranspose(semitones:)`).
    public var transposeSemitones: Int
    /// Linear gain in `0...1`, as an instrument strip's.
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

    var deckTrack: RecordingDeck.Track {
        RecordingDeck.Track(
            id: id, pcmPath: pcmFile.path, offsetSeconds: offsetSeconds, transposeSemitones: transposeSemitones,
            volume: volume, isMuted: isMuted, isSoloed: isSoloed,
        )
    }
}

/// The alignment as the host last set it.
struct RecordingAlignment {
    var warp: PlaybackTimeWarp?
    var segments: [RecordingSegment] = []
    var trackSegments: [String: [RecordingSegment]] = [:]

    /// A span, a shared segment or a segment of a track's own table: the transport then follows it and time is
    /// reported on the warped clock.
    var isSet: Bool {
        !(warp?.spans.isEmpty ?? true) || !segments.isEmpty || trackSegments.values.contains { !$0.isEmpty }
    }
}

// Recordings under the score, as the Apple and Android engines play them: one SwiftySynth render
// (`HostedSynth.renderMix`, `Shared+Render.swift`) mixes them onto the score synth, follows their alignment and
// stretches them through Signalsmith away from 100 % or transposed. The engine keeps the host's tracks and alignment
// and hands them to every score synth it builds. Called from the host's control thread, like every other control call.

extension WindowsPlaybackEngine {
    // MARK: Tracks and mix

    /// Replaces the recordings mixed with the score, each played at its strip's mix. Callable while playing: a track
    /// whose `id` was already playing carries on from where it is, and a track that keeps its `id` and `pcmFile`
    /// keeps its mapping.
    ///
    /// Every other file is mapped before anything changes: one that cannot be (`MappedRecording.Failure`) throws, and
    /// the recordings already playing stay as they were. A soloed track silences every unsoloed instrument strip.
    /// The tracks belong to the host, not to the score: they survive `prepare(score:)` and `teardown()`.
    public func setRecordingTracks(_ tracks: [RecordingTrack]) throws {
        try recordingDeck.replace(with: tracks.map(\.deckTrack))
        applyRecordingMix()
        prefetchRecordings()
    }

    /// Sets a recording strip's volume (linear, `0...1`), mute and solo. Solo is one bus across recordings and
    /// instrument strips. No-op for an id not in the track list.
    public func setRecordingMix(id: String, volume: Float, isMuted: Bool, isSoloed: Bool) {
        var tracks = recordingDeck.tracks.map(\.track)
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].volume = volume
        tracks[index].isMuted = isMuted
        tracks[index].isSoloed = isSoloed
        // Every file is mapped already under the same id and path: nothing to throw.
        try? recordingDeck.replace(with: tracks)
        applyRecordingMix()
    }

    /// The recordings resolved against the solo bus and the reader's transposition, handed to the score synth; and
    /// the instrument strips re-applied, since a recording's solo silences them.
    func applyRecordingMix() {
        let deck = recordingDeck
        let synth = core.shared.withLock { shared -> SynthHandle? in
            shared.recordingSoloed = deck.hasSoloedTrack
            shared.applyMixerState()
            return shared.session?.score
        }
        guard let synth else { return }
        let (soloing, transpose) = core.shared.withLock { ($0.isSoloing, $0.transposeSemitones) }
        synth.host.setRecordingTracks(deck.renders(soloing: soloing, readerTransposeSemitones: transpose))
    }

    // MARK: Alignment

    /// The alignment the transport and the recordings follow: `warp` sets how long each stretch of the transport's
    /// clock lasts (nil = the notated tempo), and `segments` which seconds of the reference recording sound at each
    /// warped second. Callable while playing: a table swap, never a stop, a seek or a reload.
    ///
    /// While one is set (`hasAlignment`), `currentTimeSeconds`, `currentTimeSecondsContinuous` and `totalTimeSeconds`
    /// report warped seconds — the recording's time at 100 % — and `seek(toTimeSeconds:)` and `skip(by:)` take them.
    /// `notatedTimeSecondsContinuous` stays on the notated timeline; `notatedSeconds(forReportedSeconds:)` and
    /// `reportedSeconds(forNotatedSeconds:)` convert. Survives `prepare(score:)` and `teardown()`.
    public func setAlignment(warp: PlaybackTimeWarp?, segments: [RecordingSegment]) {
        setAlignment(warp: warp, segments: segments, trackSegments: [:])
    }

    /// The alignment with segment tables of a track's own: a track whose `id` is a key of `trackSegments` plays from
    /// that table, in its own file's seconds, and its `offsetSeconds` is not applied.
    public func setAlignment(
        warp: PlaybackTimeWarp?, segments: [RecordingSegment], trackSegments: [String: [RecordingSegment]],
    ) {
        alignment = RecordingAlignment(warp: warp, segments: segments, trackSegments: trackSegments)
        let synth = core.shared.withLock { $0.session?.score }
        synth?.host.setPlaybackAlignment(warp: warp, segments: segments, trackSegments: trackSegments)
        prefetchRecordings()
    }

    /// Whether the transport follows an alignment; time is then reported on the warped clock.
    public var hasAlignment: Bool {
        alignment.isSet
    }

    // MARK: Clocks

    /// The notated position in seconds, continuous — the score's own timeline whatever the alignment, as the Apple
    /// engine's `notatedTimeSecondsContinuous`.
    public var notatedTimeSecondsContinuous: TimeInterval {
        guard let derivation = loaded?.derivation else { return 0 }
        let tick = core.shared.withLock { $0.foldedReportedScoreTick }
        return derivation.timeline.seconds(atTick: derivation.unroll.notatedTick(fromUnrolled: Double(tick)))
    }

    /// The notated second that reported second `seconds` stands for: through the alignment while one is set, else
    /// the identity.
    public func notatedSeconds(forReportedSeconds seconds: TimeInterval) -> TimeInterval {
        guard hasAlignment, let synth = scoreHost else { return seconds }
        return synth.notatedSeconds(atOutput: seconds)
    }

    /// The reported second at which notated second `seconds` first plays: the inverse.
    public func reportedSeconds(forNotatedSeconds seconds: TimeInterval) -> TimeInterval {
        guard hasAlignment, let synth = scoreHost else { return seconds }
        return synth.outputSeconds(atNotated: seconds)
    }

    /// The warped second of unrolled `tick`, on the score sequence's tempo map.
    func outputSeconds(atUnrolledTick tick: Int) -> TimeInterval? {
        guard hasAlignment, let synth = scoreHost else { return nil }
        return synth.outputSeconds(atTransport: synth.transportSeconds(atTick: tick))
    }

    /// The unrolled tick at warped second `seconds`.
    func unrolledTick(atOutputSeconds seconds: TimeInterval) -> Int? {
        guard hasAlignment, let synth = scoreHost else { return nil }
        return synth.tick(atTransportSeconds: synth.transportSeconds(atOutput: seconds))
    }

    var scoreHost: HostedSynth? {
        core.shared.withLock { $0.session?.score.host }
    }

    // MARK: Reading ahead

    /// Asks for the pages each recording plays over the next couple of seconds, from where the transport is and from
    /// the loop's start, to be read in (`MappedRecording.prefetch`). Advice, off the render thread: after a play, a
    /// seek, a new alignment or track list; a host polling the cursor calls it every few polls.
    public func prefetchRecordings() {
        guard !recordingDeck.tracks.isEmpty, let synth = scoreHost else { return }
        let loopStart = core.shared.withLock { $0.transportLoop?.startTick }
        synth.prefetchRecordings(loopStartTransportSeconds: loopStart.map { synth.transportSeconds(atTick: $0) })
    }

    // MARK: Score synths

    /// Hands `synth`, a score synth about to render `score`, what the host set: the stretcher (a new synth only, before
    /// its first track list), the tracks, the alignment, and how its sequence lies over the notated timeline.
    func installRecordings(on synth: SynthHandle, isNew: Bool, score: Score) {
        if isNew {
            synth.host.setRecordingStretcherFactory(.signalsmith)
        }
        synth.host.setUnrolledTimeMap(AudioMidiBridge.unrolledTimeMap(score: score))
        guard isNew else { return }
        let (soloing, transpose) = core.shared.withLock { ($0.isSoloing, $0.transposeSemitones) }
        synth.host.setRecordingTracks(recordingDeck.renders(soloing: soloing, readerTransposeSemitones: transpose))
        synth.host.setPlaybackAlignment(
            warp: alignment.warp, segments: alignment.segments, trackSegments: alignment.trackSegments,
        )
    }

    /// The speed a count-in of the metronome sequence's first `preRollTicks` counts at under a warp, into where the
    /// score sequence is parked — `HostedSynth.countIn(seconds:)`; nil without a warp, keeping the user's rate.
    static func countInSpeed(session: Session, preRollTicks: Int) -> Double? {
        let seconds = session.metronome.host.transportSeconds(atTick: preRollTicks)
        return session.score.host.countIn(seconds: seconds).speed
    }
}
