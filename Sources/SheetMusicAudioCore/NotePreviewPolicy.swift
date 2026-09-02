/// One sounding audition, as the pair of MIDI coordinates that identify it.
public struct PreviewVoice: Equatable, Sendable {
    public let channel: UInt8
    public let pitch: UInt8

    public init(channel: UInt8, pitch: UInt8) {
        self.channel = channel
        self.pitch = pitch
    }
}

/// Everything an engine has to do to sound one audition, decided in one place for both platforms.
///
/// A plan is spent by executing it: silence ``supersedes`` if it is there, start ``voice``, then come back to
/// ``NotePreviewPolicy/end(generation:)`` after ``ringMilliseconds`` and keep the audio graph rendering for a
/// further ``releaseTailMilliseconds``. How each of those is said in MIDI, and what "keep the graph rendering"
/// means, stays with the engine — that part is genuinely different on each platform.
public struct PreviewPlan: Equatable, Sendable {
    /// Identifies this audition for the whole of its life. Hand it back to ``NotePreviewPolicy/end(generation:)``.
    public let generation: UInt64
    /// The audition this one replaces, to be silenced before the new note starts, or `nil` when none was sounding.
    public let supersedes: PreviewVoice?
    public let voice: PreviewVoice
    public let velocity: UInt8
    /// True when the note is on a drum staff. Some synths need a different message to stop a one-shot than to
    /// stop a held note, which is the engine's business; the policy carries the fact rather than the message.
    public let isDrum: Bool
    /// How long the note rings before the engine ends it.
    public let ringMilliseconds: Int
    /// How much longer the audio graph must keep rendering after that end, so the note's release is heard.
    ///
    /// Whether parking the graph would actually cut a release is the engine's own to know — an `AVAudioEngine`
    /// driving an AU instrument releases cleanly through a pause, where a software synth freezes mid-release.
    /// The number is the same either way; only who acts on it differs.
    public let releaseTailMilliseconds: Int

    /// ``ringMilliseconds`` in seconds, for a scheduler that takes a `TimeInterval`.
    public var ringSeconds: Double {
        Double(ringMilliseconds) / 1000
    }

    /// ``releaseTailMilliseconds`` in seconds, for a scheduler that takes a `TimeInterval`.
    public var releaseTailSeconds: Double {
        Double(releaseTailMilliseconds) / 1000
    }
}

/// When one audition supersedes another, and how long each one occupies the audio graph.
///
/// The playback engines on both platforms own this state, and owned it twice: Android's copy was written months
/// after Apple's and reproduced neither the supersede nor the release tail, so entering notes quickly on Android
/// dropped previews (a stale end action silenced the note that had replaced it) and every audition from an idle
/// Reader clicked (the graph was parked before the release rendered). Both were audible, and both were bugs that
/// the other platform had already found and fixed.
///
/// So the decisions live here and the engines execute them: Apple holds this struct directly, Android reaches it
/// over JNI (`NotePreviewCoordinator` in `SheetMusicBridgeCore` wraps it for that). A pure value type keeps it
/// testable on the host and portable to WebAssembly, and keeps every timing constant in one file.
///
/// Not thread-safe by itself, deliberately: Apple's engine is already main-actor isolated, and the JNI wrapper
/// serializes on its own lock. A lock in here would be dead weight in the first case and the wrong granularity
/// in the second.
public struct NotePreviewPolicy: Equatable, Sendable {
    /// How long a drum audition rings, regardless of the duration asked for.
    ///
    /// A cymbal's musical value is its decay, so a drum preview is not over when a melodic one would be. By-ear
    /// tunable — this is the number Apple arrived at by ear and Android never had.
    public static let drumRingMilliseconds = 2000

    /// How long the audio graph must keep rendering after a note-off, before it may be parked.
    ///
    /// The note-off starts the release; the graph is what renders it. Parking immediately chops the tail into a
    /// click — and on a software synth it also freezes the render thread mid-release, so the remains of the tail
    /// resume audibly on the next audition. By-ear tunable.
    public static let releaseTailMilliseconds = 800

    /// The audition currently sounding, or `nil` when none is.
    public private(set) var sounding: PreviewVoice?

    /// The generation of the most recent ``begin(voice:velocity:isDrum:ringMilliseconds:)``.
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Plans one audition, superseding whatever was sounding.
    ///
    /// The returned plan's generation is what makes a superseded end action harmless: only the newest generation
    /// still answers ``end(generation:)``, so an end scheduled by a note that has since been replaced arrives to
    /// find it is no longer the note being talked about. Without that, an end action fired on its own schedule
    /// and silenced its successor — which is only audible when the successor landed on the same channel and
    /// pitch, and so presented as previews going intermittently missing.
    public mutating func begin(
        voice: PreviewVoice,
        velocity: UInt8,
        isDrum: Bool,
        ringMilliseconds: Int,
    ) -> PreviewPlan {
        generation &+= 1
        let superseded = sounding
        sounding = voice
        return PreviewPlan(
            generation: generation,
            supersedes: superseded,
            voice: voice,
            velocity: velocity,
            isDrum: isDrum,
            ringMilliseconds: isDrum ? Self.drumRingMilliseconds : ringMilliseconds,
            releaseTailMilliseconds: Self.releaseTailMilliseconds,
        )
    }

    /// The note to silence now that `generation`'s ring time is up, or `nil` if that audition was superseded.
    ///
    /// Idempotent for a given generation: the second call answers `nil`, because the first one ended it.
    public mutating func end(generation: UInt64) -> PreviewVoice? {
        guard generation == self.generation, let voice = sounding else { return nil }
        sounding = nil
        return voice
    }

    /// Whether `generation` is still the audition in progress.
    ///
    /// For work an engine defers past the note-off — parking the graph, in practice. A newer audition means the
    /// graph is wanted again, and the deferred work must not run.
    public func isCurrent(generation: UInt64) -> Bool {
        generation == self.generation
    }

    /// Abandons any audition in progress, answering the note that has to be silenced for that to be true.
    ///
    /// For teardown and for re-preparing on a different score. Bumps the generation, so end actions already
    /// scheduled against the abandoned audition find themselves superseded rather than firing into the new state.
    public mutating func silence() -> PreviewVoice? {
        generation &+= 1
        defer { sounding = nil }
        return sounding
    }
}
