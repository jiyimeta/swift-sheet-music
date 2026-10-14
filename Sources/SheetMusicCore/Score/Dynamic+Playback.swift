import SheetMusicFoundation

extension Dynamic {
    /// What a dynamic does to playback, as MuseScore 4's playback model reads it (`PlaybackContext::updateDynamicMap`,
    /// `engraving/playback/playbackcontext.cpp:384-428`; its tables are `playback/utils/expressionutils.h:33-109`) —
    /// the one place the SMF's voice walk (`MidiRenderer.renderVoice`) and `HairpinRamps` learn it from. Velocities are
    /// `dynList` velocities (`defaultVelocity(for:)`), before an instrument's velocity scale.
    public enum PlaybackRole: Sendable, Equatable {
        /// An ordinary dynamic: the running level from its own chord on.
        case level(velocity: Int)
    }

    /// Every dynamic is a running level at its stored velocity — the rule the SMF has always followed.
    public var playbackRole: PlaybackRole {
        .level(velocity: velocity)
    }
}
