import Foundation

/// MuseScore wire-format major version targeted by the MSCX encoder
/// and recognised by the MSCX decoder.
///
/// `v4` is the current default. `v3` covers MuseScore 3.x readers
/// (programVersion 3.6.2 in `~/Desktop/test-min.mscx`).
public enum MSCXVersion: Sendable, Hashable {
    /// MuseScore 3.x — `<museScore version="3.02">`, programVersion 3.6.2.
    case v3
    /// MuseScore 4.x — `<museScore version="4.60">`.
    case v4
}
