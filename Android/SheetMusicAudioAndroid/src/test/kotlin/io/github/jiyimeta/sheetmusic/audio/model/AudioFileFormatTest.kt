package io.github.jiyimeta.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioFileFormatTest {
    @Test fun pcmOptionsDefaultIsStereoInt16At44100() {
        val opts = PcmOptions()
        assertEquals(44100, opts.sampleRate)
        assertEquals(PcmBitDepth.Int16, opts.bitDepth)
        assertEquals(AudioChannelCount.Stereo, opts.channels)
    }

    @Test fun compressedOptionsDefaultIs192kbps() {
        val opts = CompressedOptions()
        assertEquals(44100, opts.sampleRate)
        assertEquals(192_000, opts.bitRate)
        assertEquals(AudioChannelCount.Stereo, opts.channels)
    }

    @Test fun audioFileFormatVariantsCarryTheirOptions() {
        val pcm = PcmOptions(
            sampleRate = 48000,
            bitDepth = PcmBitDepth.Float32,
            channels = AudioChannelCount.Mono,
        )
        val wav = AudioFileFormat.Wav(pcm)
        assertEquals(48000, wav.options.sampleRate)
        val compressed = CompressedOptions(
            sampleRate = 22050,
            bitRate = 96_000,
            channels = AudioChannelCount.Mono,
        )
        val mp3 = AudioFileFormat.Mp3(compressed)
        assertEquals(96_000, mp3.options.bitRate)
    }

    @Test fun audioChannelCountRawValueMatchesChannelCount() {
        assertEquals(1, AudioChannelCount.Mono.rawValue)
        assertEquals(2, AudioChannelCount.Stereo.rawValue)
    }
}
