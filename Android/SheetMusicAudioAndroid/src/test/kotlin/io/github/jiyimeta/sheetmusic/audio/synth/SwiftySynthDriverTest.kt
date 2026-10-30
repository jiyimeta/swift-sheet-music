package io.github.jiyimeta.sheetmusic.audio.synth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Where a SoundFont is read from. A `file:` URI is opened in place, so SwiftySynth maps it and the ~205 MB
 * high-quality font is neither copied into the cache nor counted against the app's memory; anything else goes
 * through the content resolver into the cache, as before.
 */
class SwiftySynthDriverTest {

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
}
