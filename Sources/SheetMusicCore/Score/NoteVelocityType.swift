import Foundation

/// How a note's `Note.userVelocity` combines with the velocity derived
/// from the prevailing dynamic. C++: `mu::engraving::VeloType`
/// (`<veloType>` in MSCX).
///
/// MuseScore changed the *default* between wire-format generations, so
/// the decoder resolves an absent `<veloType>` from the file version
/// rather than from this enum:
///
/// * MuseScore 3 defaulted to `.offset` and wrote `<veloType>user</veloType>`
///   explicitly for absolute velocities.
/// * MuseScore 4 defaulted to `.user` and stopped writing `<veloType>`
///   altogether — its note inspector edits an absolute MIDI velocity.
public enum NoteVelocityType: String, Sendable, Hashable, CaseIterable {
    /// `userVelocity` is a signed percentage applied to the dynamic's
    /// velocity: `velo + velo * userVelocity / 100`.
    case offset
    /// `userVelocity` *is* the MIDI velocity, replacing the dynamic's.
    case user

    /// The MSCX token MuseScore writes / reads for this case.
    public var mscxToken: String {
        rawValue
    }

    /// Parse a `<veloType>` token. Unknown tokens return nil so the
    /// caller can fall back to the file-version default.
    public init?(mscxToken: String) {
        self.init(rawValue: mscxToken.lowercased())
    }
}

extension Note {
    /// Resolve this note's sounding velocity from the velocity the
    /// prevailing dynamic (plus hairpin ramp / articulation scaling)
    /// produced for the chord.
    ///
    /// A `userVelocity` of 0 means "no override" and returns `velocity`
    /// untouched — matching the `if (note->userVelocity() != 0)` guard
    /// in `CompatMidiRender::playNote`. Otherwise the result is clamped
    /// to MIDI's audible `1...127`.
    ///
    /// Mirrors `mu::engraving::Note::customizeVelocity`
    /// (`engraving/dom/note.cpp`).
    public func customizedVelocity(_ velocity: Int) -> Int {
        guard userVelocity != 0 else { return velocity }
        let raw: Int
        switch velocityType {
        case .offset:
            raw = velocity + (velocity * userVelocity) / 100
        case .user:
            raw = userVelocity
        }
        return min(127, max(1, raw))
    }
}
