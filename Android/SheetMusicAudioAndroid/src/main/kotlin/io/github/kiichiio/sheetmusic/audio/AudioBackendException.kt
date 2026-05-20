package io.github.kiichiio.sheetmusic.audio

/** Sealed exception hierarchy for the Android audio backend. */
sealed class AudioBackendException(message: String) : Exception(message) {
    class NoSoundfont : AudioBackendException("No SoundFont available")
    class StreamUnavailable(cause: String) :
        AudioBackendException("Audio stream open failed: $cause")
    class InvalidScoreHandle :
        AudioBackendException("Score handle was not recognized")
    class EmptyScore : AudioBackendException("Score has zero staves")
    class TooManyStaves(val staffCount: Int) :
        AudioBackendException("Score has $staffCount staves; v0 supports up to 16")
    class FluidSynthInit(cause: String) :
        AudioBackendException("FluidSynth initialization failed: $cause")
}
