import SheetMusicFoundation

extension Dynamic {
    /// What a dynamic does to playback, as MuseScore 4's playback model reads it (`PlaybackContext::updateDynamicMap`,
    /// `engraving/playback/playbackcontext.cpp:384-428`; its tables are `playback/utils/expressionutils.h:33-109`) —
    /// the one place the SMF's voice walk (`MidiRenderer.renderVoice`) and `HairpinRamps` learn it from. Velocities are
    /// `dynList` velocities (`defaultVelocity(for:)`), before an instrument's velocity scale.
    public enum PlaybackRole: Sendable, Equatable {
        /// An ordinary dynamic: the running level from its own chord on.
        case level(velocity: Int)
        /// No effect on playback: a dynamic MuseScore 4's tables do not list, or one with `<play>0</play>`.
        case none
    }

    /// MuseScore 4's tables (`playback/utils/expressionutils.h`): an ordinary level (`ORDINARY_DYNAMIC_LEVELS`, 33-49)
    /// keeps its stored velocity, as the SMF always has (spec 2026-10-14 §7.3); niente is the softest of them; a
    /// dynamic none of the tables lists — fz, m, r, s, z, `other-dynamics`, a token MuseScore reads as OTHER — and any
    /// dynamic with `<play>0</play>` does nothing (`updateDynamicMap`, `playbackcontext.cpp:386-388`).
    public var playbackRole: PlaybackRole {
        guard playsBack else { return .none }
        switch subtype {
        case "pppppp", "ppppp", "pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff", "fffff", "ffffff":
            return .level(velocity: velocity)
        case "n":
            // MuseScore 4's niente is level `ppppppppp`, 0 (`expressionutils.h:34`); a MIDI velocity of 0 is a
            // note-off, so the softest one there is.
            return .level(velocity: 1)
        case "sf", "sfz", "sff", "sffz", "sfff", "sfffz", "rf", "rfz", "fp", "pf", "sfp", "sfpp":
            // The single-note and two-level dynamics: a running level at their own velocity, as the SMF has played
            // them so far.
            return .level(velocity: velocity)
        default:
            // fz, m, r, s, z, other-dynamics, and any token MuseScore reads as OTHER (`Dynamic::parseDynamicText`,
            // `engraving/dom/dynamic.cpp:242-258`).
            return .none
        }
    }
}
