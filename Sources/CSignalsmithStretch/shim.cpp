#include "csignalsmith_stretch.h"

#include "signalsmith-stretch/signalsmith-stretch.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <new>
#include <vector>

struct CSignalsmithStretch {
    // Seeded from `std::random_device`; the stretcher draws random phases only past a 2x stretch (a rate under 0.5).
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    // Where `csignalsmith_stretch_seek` drops the output it runs to fill the stretcher: one block per channel, sized
    // at create so a seek allocates nothing.
    std::vector<float> discardLeft;
    std::vector<float> discardRight;
};

extern "C" {

CSignalsmithStretch *csignalsmith_stretch_create(double sampleRate, bool cheaper) {
    try {
        auto stretch = std::make_unique<CSignalsmithStretch>();
        if (cheaper) {
            stretch->stretch.presetCheaper(2, static_cast<float>(sampleRate));
        } else {
            stretch->stretch.presetDefault(2, static_cast<float>(sampleRate));
        }
        stretch->discardLeft.assign(static_cast<size_t>(stretch->stretch.blockSamples()), 0);
        stretch->discardRight.assign(static_cast<size_t>(stretch->stretch.blockSamples()), 0);
        return stretch.release();
    } catch (const std::bad_alloc &) {
        return nullptr;
    }
}

void csignalsmith_stretch_destroy(CSignalsmithStretch *stretch) {
    delete stretch;
}

int csignalsmith_stretch_input_latency(const CSignalsmithStretch *stretch) {
    return stretch->stretch.inputLatency();
}

int csignalsmith_stretch_output_latency(const CSignalsmithStretch *stretch) {
    return stretch->stretch.outputLatency();
}

void csignalsmith_stretch_set_transpose_semitones(CSignalsmithStretch *stretch, double semitones) {
    stretch->stretch.setTransposeSemitones(static_cast<float>(semitones));
}

void csignalsmith_stretch_reset(CSignalsmithStretch *stretch) {
    stretch->stretch.reset();
}

/// The input that fills the stretcher's output after a seek: one block of output at `rate`.
static int primingInputFrames(const CSignalsmithStretch *stretch, double rate) {
    return static_cast<int>(std::lround(rate * stretch->stretch.blockSamples()));
}

int csignalsmith_stretch_seek_length(const CSignalsmithStretch *stretch, double rate) {
    return stretch->stretch.seekLength() + primingInputFrames(stretch, rate);
}

void csignalsmith_stretch_seek(
    CSignalsmithStretch *stretch, const float *left, const float *right, int frames, double rate
) {
    // Upstream's `seek` only replaces the input history, so after a reset the output would rise from silence over a
    // block. Running one block of output through it first — the output that history makes is what is discarded —
    // leaves the next output aligned and at full level, as a stretcher that had been playing this input all along.
    const int primingInput = std::min(frames, primingInputFrames(stretch, rate));
    const int history = frames - primingInput;
    const float *historyChannels[2] = {left, right};
    stretch->stretch.seek(historyChannels, history, rate);
    const float *primingChannels[2] = {left + history, right + history};
    float *discardChannels[2] = {stretch->discardLeft.data(), stretch->discardRight.data()};
    stretch->stretch.process(primingChannels, primingInput, discardChannels, stretch->stretch.blockSamples());
}

void csignalsmith_stretch_process(
    CSignalsmithStretch *stretch,
    const float *inputLeft, const float *inputRight, int inputFrames,
    float *outputLeft, float *outputRight, int outputFrames
) {
    const float *inputs[2] = {inputLeft, inputRight};
    float *outputs[2] = {outputLeft, outputRight};
    stretch->stretch.process(inputs, inputFrames, outputs, outputFrames);
}

}
