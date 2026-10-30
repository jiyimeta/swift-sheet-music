package io.github.jiyimeta.sheetmusic.audio.synth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [SwiftySynthDriver] against a recording stand-in for the native calls: where a SoundFont is read from, and the
 * lifetime of the synth handle — which is a retained Swift object's address, so any call that reaches native code
 * with it after [SwiftySynthDriver.close] is a use-after-free.
 */
class SwiftySynthDriverTest {

    private class RecordingNative : SynthNativeCalls {
        val calls = mutableListOf<String>()

        override fun synthRelease(handle: Long) { calls += "synthRelease($handle)" }
        override fun synthLoadSoundFont(handle: Long, path: String): Int { calls += "load($handle,$path)"; return 0 }
        override fun synthProgramSelect(handle: Long, channel: Int, bank: Int, program: Int) {
            calls += "programSelect($handle)"
        }
        override fun synthControlChange(handle: Long, channel: Int, controller: Int, value: Int) {
            calls += "cc($handle)"
        }
        override fun synthControllerValue(handle: Long, channel: Int, controller: Int): Int {
            calls += "getCC($handle)"
            return 100
        }
        override fun synthSetGain(handle: Long, gain: Float) { calls += "gain($handle)" }
        override fun synthNoteOn(handle: Long, channel: Int, key: Int, velocity: Int) { calls += "noteOn($handle)" }
        override fun synthNoteOff(handle: Long, channel: Int, key: Int) { calls += "noteOff($handle)" }
        override fun synthAllNotesOff(handle: Long, channel: Int) { calls += "allNotesOff($handle)" }
        override fun nativeRender(handle: Long, frames: Int, left: FloatArray, right: FloatArray): Int {
            calls += "render($handle)"
            return frames
        }
        override fun sequenceCreate(synthHandle: Long, smf: ByteArray): Long {
            calls += "sequenceCreate($synthHandle,${smf.size})"
            return 99L
        }
    }

    @Test fun aFileUriIsReadInPlace() {
        assertEquals(
            "/data/user/0/app/files/gm.sf2",
            soundFontFilePath("file", "/data/user/0/app/files/gm.sf2"),
        )
    }

    @Test fun aContentUriIsCopiedFirst() {
        assertNull(soundFontFilePath("content", "/document/primary:Download/gm.sf2"))
    }

    @Test fun aFileUriWithoutAPathIsCopiedFirst() {
        assertNull(soundFontFilePath("file", null))
        assertNull(soundFontFilePath("file", ""))
        assertNull(soundFontFilePath(null, "/x.sf2"))
    }

    @Test fun anOpenDriverAttachesASequenceThroughItsOwnHandle() {
        val native = RecordingNative()
        val driver = SwiftySynthDriver(7L, native)

        assertEquals(99L, driver.attachSequence(ByteArray(16)))
        assertEquals(listOf("sequenceCreate(7,16)"), native.calls)
    }

    /**
     * The race the raw handle used to lose: a prepare tears the synth down on its IO thread while a play on the main
     * thread builds a player for it. Attaching goes through the driver and its lock, so a closed synth yields no
     * sequence and no native call with the released handle.
     */
    @Test fun aClosedDriverAttachesNothingAndNeverReachesNativeCodeAgain() {
        val native = RecordingNative()
        val driver = SwiftySynthDriver(7L, native)

        driver.close()
        val attached = driver.attachSequence(ByteArray(16))
        driver.noteOn(0, 60, 100)
        driver.cc(0, 7, 0)
        val rendered = driver.writeFloat(4, FloatArray(4), FloatArray(4))
        driver.close()

        assertEquals(0L, attached)
        assertEquals(0, rendered)
        assertEquals(listOf("synthRelease(7)"), native.calls)
    }
}
