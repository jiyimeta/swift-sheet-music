import SheetMusicFoundation

extension Dynamic {
    /// What a dynamic does to playback, as MuseScore 4's playback model reads it (`PlaybackContext::updateDynamicMap`,
    /// `engraving/playback/playbackcontext.cpp:384-428`; its tables are `playback/utils/expressionutils.h:33-109`) —
    /// the one place the SMF's voice walk (`MidiRenderer.renderVoice`) and `HairpinRamps` learn it from. Velocities are
    /// `dynList` velocities (`defaultVelocity(for:)`), before an instrument's velocity scale.
    package enum PlaybackRole: Sendable, Equatable {
        /// An ordinary dynamic: the running level from its own chord on.
        case level(velocity: Int)
        /// A single-note dynamic: only the chord on its tick plays `velocity`; the running level is untouched.
        case accent(velocity: Int)
        /// A two-level dynamic: `from` on its own chord, six linear steps to `to` over `velocityChangeTicks`, then `to`
        /// as the running level.
        case transition(from: Int, to: Int)
        /// No effect on playback: a dynamic MuseScore 4's tables do not list, or one with `<play>0</play>`.
        case none
    }

    /// MuseScore 4's tables (`playback/utils/expressionutils.h`): an ordinary level (`ORDINARY_DYNAMIC_LEVELS`, 33-49)
    /// keeps its stored velocity, as the SMF always has (spec 2026-10-14 §7.3); niente is the softest of them; a
    /// single-note dynamic accents its own chord at its level's velocity (`SINGLE_NOTE_DYNAMIC_LEVELS`, 67-76) — its
    /// stored `<velocity>` is MuseScore 3's, which MuseScore 4 ignores; a two-level dynamic changes from its first
    /// level to its second (`COMPOUND_DYNAMICS`, 104-109); a dynamic none of the tables lists — fz, m, r, s, z,
    /// `other-dynamics`, a token MuseScore reads as OTHER — and any dynamic with `<play>0</play>` does nothing
    /// (`updateDynamicMap`, `playbackcontext.cpp:386-388`).
    package var playbackRole: PlaybackRole {
        guard playsBack else { return .none }
        switch subtype {
        case "pppppp", "ppppp", "pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff", "fffff", "ffffff":
            return .level(velocity: velocity)
        case "n":
            // MuseScore 4's niente is level `ppppppppp`, 0 (`expressionutils.h:34`); a MIDI velocity of 0 is a
            // note-off, so the softest one there is.
            return .level(velocity: 1)
        case "sf", "sfz", "rf", "rfz":
            return .accent(velocity: Self.defaultVelocity(for: "f"))
        case "sff", "sffz":
            return .accent(velocity: Self.defaultVelocity(for: "ff"))
        case "sfff", "sfffz":
            return .accent(velocity: Self.defaultVelocity(for: "fff"))
        case "fp", "sfp":
            return .transition(from: Self.defaultVelocity(for: "f"), to: Self.defaultVelocity(for: "p"))
        case "pf":
            return .transition(from: Self.defaultVelocity(for: "p"), to: Self.defaultVelocity(for: "f"))
        case "sfpp":
            return .transition(from: Self.defaultVelocity(for: "f"), to: Self.defaultVelocity(for: "pp"))
        default:
            // fz, m, r, s, z, other-dynamics, and any token MuseScore reads as OTHER (`Dynamic::parseDynamicText`,
            // `engraving/dom/dynamic.cpp:242-258`).
            return .none
        }
    }

    /// How long a two-level change takes, in ticks at `division` — MuseScore's `velocityChangeLength`
    /// (`engraving/dom/dynamic.cpp:174-196`): 0.8 of a quarter at 120 BPM at the normal speed, 1.3 slow, 0.5 fast,
    /// scaled by the tempo where the dynamic stands, so it lasts 0.4 / 0.65 / 0.25 s at any tempo. MuseScore's fixed
    /// division (480) is `division` here, which is the same for every MuseScore file. A `<veloChange>` of 0, which
    /// makes MuseScore's change instant, is not modeled.
    package func velocityChangeTicks(beatsPerSecond: Double, division: Int) -> Int {
        let ratio = beatsPerSecond / ResolvedTempoMap.defaultBeatsPerSecond
        return Int(ratio * (velocityChangeSpeed.quarterNotes * Double(division)))
    }

    /// A two-level change's seven points — six steps and the level it lands on — as `(offset, velocity)`: MuseScore's
    /// `TConv::easingValueCurve(ticks, 6, to − from, NORMAL)` (`engraving/types/typesconv.cpp:1928-1951`), its value
    /// truncated to an integer as MuseScore truncates it, here in velocity rather than MuseScore 4's expression level.
    package static func transitionSteps(from: Int, to: Int, ticks: Int) -> [(offset: Int, velocity: Int)] {
        ResolvedTempoMap.easedCurve(ticks: ticks, steps: 6, amplitude: Double(to - from), method: .normal)
            .map { (offset: $0.offset, velocity: from + Int($0.delta)) }
    }
}

extension Dynamic.VelocityChangeSpeed {
    /// `velocityChangeLength`'s speed multiplier: the change's length in quarter notes at 120 BPM.
    var quarterNotes: Double {
        switch self {
        case .normal: 0.8
        case .slow: 1.3
        case .fast: 0.5
        }
    }
}
