import SheetMusicFoundation

/// A host's recording strips and their mapped files, for an engine whose host describes them by path — Android's,
/// through JNI. Resolves them to what a backend mixes by the one rule the Apple engine reads too
/// (`RecordingTrackRender.resolved`), and keeps each file mapped for as long as its track keeps its `id` and its path,
/// as `PlaybackEngine.setRecordingTracks` does, so a change of mix hands the backend the same recording and a track
/// read through a stretcher carries on rather than restarting.
package struct RecordingDeck {
    /// One recording strip as the host describes it.
    package struct Track: Equatable, Sendable {
        package var id: String
        package var pcmPath: String
        package var offsetSeconds: Double
        package var transposeSemitones: Int
        package var volume: Float
        package var isMuted: Bool
        package var isSoloed: Bool

        package init(
            id: String, pcmPath: String, offsetSeconds: Double, transposeSemitones: Int, volume: Float,
            isMuted: Bool, isSoloed: Bool,
        ) {
            self.id = id
            self.pcmPath = pcmPath
            self.offsetSeconds = offsetSeconds
            self.transposeSemitones = transposeSemitones
            self.volume = volume
            self.isMuted = isMuted
            self.isSoloed = isSoloed
        }
    }

    package private(set) var tracks: [(track: Track, recording: MappedRecording)] = []

    package init() {}

    /// Replaces the strips. Every file not already mapped under the same `id` and path is mapped first; one that
    /// cannot be throws (`MappedRecording.Failure`) and leaves the strips as they were.
    package mutating func replace(with incoming: [Track]) throws {
        let previous = tracks
        tracks = try incoming.map { track in
            let kept = previous.first { $0.track.id == track.id && $0.track.pcmPath == track.pcmPath }
            return try (track, kept?.recording ?? MappedRecording(path: track.pcmPath))
        }
    }

    /// Whether any strip is soloed — it engages the solo bus the instrument strips share.
    package var hasSoloedTrack: Bool {
        tracks.contains { $0.track.isSoloed }
    }

    /// The strips as the backend mixes them, against the solo bus as the host has it (`soloing`: any instrument strip
    /// or recording soloed) and the reader's transposition.
    package func renders(soloing: Bool, readerTransposeSemitones: Int) -> [RecordingTrackRender] {
        tracks.map { loaded in
            let track = loaded.track
            return RecordingTrackRender.resolved(
                id: track.id, recording: loaded.recording, offsetSeconds: track.offsetSeconds,
                transposeSemitones: track.transposeSemitones, readerTransposeSemitones: readerTransposeSemitones,
                volume: track.volume, isMuted: track.isMuted, isSoloed: track.isSoloed, soloing: soloing,
            )
        }
    }
}
