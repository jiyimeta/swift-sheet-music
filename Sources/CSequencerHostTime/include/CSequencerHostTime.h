#ifndef SHEET_MUSIC_CSEQUENCER_HOST_TIME_H
#define SHEET_MUSIC_CSEQUENCER_HOST_TIME_H

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper around `-[AVAudioSequencer hostTimeForBeats:error:]`.
///
/// DO NOT replace this with a direct Swift call to
/// `sequencer.hostTime(forBeats:error:)`. That call is unsafe on device: when
/// the underlying `MusicPlayer` has not yet reached a playing state — which
/// happens right at score-playback start, exactly when a host is likely to
/// read a timed position — `AVAudioSequencer.isPlaying` can already report
/// `true` while `hostTimeForBeats:` still rejects the beat. AVFAudio's
/// `_AVAE_CheckNoErr` reports that rejection by RAISING an Objective-C
/// exception instead of populating the `NSError **` the API advertises, so
/// the exception propagates straight past any Swift `guard error == nil`
/// and aborts the process. Observed on a physical device:
///
///     AVAudioSequencerImpl.mm:139:HostTimeForBeats:
///       (MusicPlayerGetHostTimeForBeats(mPlayer, inBeats, pOutHostTime)): error -10852
///     *** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio',
///       reason: 'error -10852'
///
///     -[AVAudioSequencer(AVAudioSequencer_Player) hostTimeForBeats:error:]
///       -> _AVAE_CheckNoErr(...) -> +[NSException raise:format:] -> objc_exception_throw -> abort
///
/// `-10852` is `kAudioToolboxErr_InvalidPlayerState`. Because `isPlaying` is
/// itself the check that lies, and the player's state can change between any
/// pre-call check and the call, no amount of guarding on the Swift side of
/// the call closes this race — Swift simply cannot catch an NSException, so
/// the only fix is an Objective-C `@try`/`@catch` shim. This function folds
/// BOTH failure paths — the exception AND the documented "error pointer
/// populated" path — into a single `NO` return, so the caller sees one
/// uniform "no pairing available" outcome regardless of which path AVFAudio
/// takes on a given OS/build.
///
/// - Parameters:
///   - sequencer: The sequencer to query. Must not be nil.
///   - beats: The beat position to translate to a host time.
///   - outHostTime: On success (`YES`), populated with the paired host time
///     (`mach_absolute_time`-space, suitable for `AVAudioTime.seconds(forHostTime:)`).
///     Left unmodified on failure.
/// - Returns: `YES` if `outHostTime` was populated, `NO` if the sequencer
///   raised or reported an error translating the beat (e.g. stopped, or the
///   beat precedes the player's starting beat).
BOOL SSMSequencerHostTimeForBeats(AVAudioSequencer *sequencer, double beats, uint64_t *outHostTime);

NS_ASSUME_NONNULL_END

#endif
