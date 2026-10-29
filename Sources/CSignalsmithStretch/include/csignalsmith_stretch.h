#ifndef CSIGNALSMITH_STRETCH_H
#define CSIGNALSMITH_STRETCH_H

// A C face for Signalsmith Stretch (MIT, vendored beside this file — see VENDORED.md), so Swift reaches it without
// C++ interop. Stereo only, which is all `RecordingStretcher` asks for.
//
// `csignalsmith_stretch_create` and `csignalsmith_stretch_destroy` allocate and free; call them off the render thread.
// Every other function allocates nothing and takes no lock once the stretcher exists.

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

typedef struct CSignalsmithStretch CSignalsmithStretch;

/// A stereo stretcher on Signalsmith's default preset (a 120 ms block every 30 ms), or its cheaper one (100 ms every
/// 40 ms, the work spread over the interval). NULL when memory runs out.
CSignalsmithStretch *_Nullable csignalsmith_stretch_create(double sampleRate, bool cheaper);
void csignalsmith_stretch_destroy(CSignalsmithStretch *stretch);

/// Frames between the last input frame fed and the processing position.
int csignalsmith_stretch_input_latency(const CSignalsmithStretch *stretch);
/// Output frames between the processing position and the output.
int csignalsmith_stretch_output_latency(const CSignalsmithStretch *stretch);

void csignalsmith_stretch_set_transpose_semitones(CSignalsmithStretch *stretch, double semitones);
void csignalsmith_stretch_reset(CSignalsmithStretch *stretch);

/// Input frames `csignalsmith_stretch_seek` takes at `rate`: a block and an interval of history, then a block of
/// output's worth of input that it runs through to fill its output.
int csignalsmith_stretch_seek_length(const CSignalsmithStretch *stretch, double rate);
/// After `csignalsmith_stretch_reset`: starts on `frames` frames that end where the next process call's input begins.
/// The output those frames produce is discarded, so the next output frame plays the input `input latency + output
/// latency × rate` frames before their end, at full level.
void csignalsmith_stretch_seek(
    CSignalsmithStretch *stretch, const float *left, const float *right, int frames, double rate
);
/// Consumes `inputFrames` and produces `outputFrames`; their ratio is the playback rate. Input and output must not
/// overlap.
void csignalsmith_stretch_process(
    CSignalsmithStretch *stretch,
    const float *inputLeft, const float *inputRight, int inputFrames,
    float *outputLeft, float *outputRight, int outputFrames
);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
