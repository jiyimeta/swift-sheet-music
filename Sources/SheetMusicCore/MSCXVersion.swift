import Foundation

/// MuseScore wire-format major version targeted by the MSCX encoder
/// and recognized by the MSCX decoder.
///
/// `v4` is the current default. `v3` covers MuseScore 3.x readers
/// (programVersion 3.6.2 in `~/Desktop/test-min.mscx`). `v2` is
/// **detection-only**: the decoder reports it when a file declares
/// `<museScore version="2.x">` so consumers can surface a "MuseScore 2"
/// badge, but the encoder normalizes `.v2` to `.v3` (see
/// `MSCXEncoderOptions.init`) and the decoder still parses MS2 files
/// through the MS3-shaped reader, so the parsed `Score` is best-effort.
public enum MSCXVersion: Sendable, Hashable {
    /// MuseScore 2.x — `<museScore version="2.06">`. Detection-only;
    /// not a supported encoder target.
    case v2
    /// MuseScore 3.x — `<museScore version="3.02">`, programVersion 3.6.2.
    case v3
    /// MuseScore 4.x — `<museScore version="4.60">`.
    case v4
}
