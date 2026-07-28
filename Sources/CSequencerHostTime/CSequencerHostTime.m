#import "CSequencerHostTime.h"

BOOL SSMSequencerHostTimeForBeats(AVAudioSequencer *sequencer, double beats, uint64_t *outHostTime) {
    NSCParameterAssert(sequencer != nil);
    NSCParameterAssert(outHostTime != NULL);

    NSError *error = nil;
    uint64_t hostTime = 0;

    // See the header comment for why this exists: `hostTimeForBeats:error:`
    // can RAISE instead of populating `error`, so the `@try`/`@catch` here is
    // the only thing standing between that internal AVFAudio assertion
    // failure and an app-terminating uncaught NSException.
    @try {
        hostTime = [sequencer hostTimeForBeats:beats error:&error];
    } @catch (NSException *exception) {
        return NO;
    }

    // The documented (non-raising) failure path: `error` populated with a
    // non-nil value. Folded into the same `NO` result as the `@catch` above
    // so callers see one uniform failure outcome.
    if (error != nil) {
        return NO;
    }

    *outHostTime = hostTime;
    return YES;
}
