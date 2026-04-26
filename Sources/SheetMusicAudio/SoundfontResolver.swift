import Foundation

/// Maps a `(bank, program)` tuple to the SoundFont (.sf2) file the
/// `PlaybackEngine` should load for that voice. App authors implement
/// this to point at whatever set of `.sf2` files they're shipping or
/// downloading at runtime.
///
/// Two tiers, in priority order:
///
/// 1. `soundfontURL(forBank:program:)` — a per-program file. These
///    are tiny (typically a few hundred KB to a few MB), so loading
///    only the patches the score actually uses keeps memory pressure
///    low — important on iPhone, where a full GM SF2 (>= ~100 MB)
///    would dominate the audio process's working set.
/// 2. `defaultGMSoundfontURL` — the full General-MIDI fallback,
///    consulted only when the per-program lookup returns `nil`.
///    Returning `nil` here too is allowed; voices without a matched
///    sound just stay silent.
public protocol SoundfontResolver: Sendable {
    func soundfontURL(forBank bank: UInt8, program: UInt8) -> URL?
    var defaultGMSoundfontURL: URL? { get }
}
