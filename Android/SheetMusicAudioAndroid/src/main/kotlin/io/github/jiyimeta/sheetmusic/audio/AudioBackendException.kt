package io.github.jiyimeta.sheetmusic.audio

import io.github.jiyimeta.sheetmusic.audio.model.AudioFileFormat

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
    class EngineSetupFailed(cause: String) :
        AudioBackendException("Engine setup failed: $cause")
    class NoScorePrepared :
        AudioBackendException("No score prepared for export")
    class RangeNotInTimeline :
        AudioBackendException("Export range is not in timeline")
    class FormatUnsupportedOnThisOS(val format: AudioFileFormat) :
        AudioBackendException("Format unsupported on this OS: $format")
    class FileWriteFailed(cause: Throwable?) :
        AudioBackendException("File write failed: ${cause?.message ?: "unknown"}") {
        init { initCause(cause) }
    }
    class Cancelled :
        AudioBackendException("Export was cancelled")
}
