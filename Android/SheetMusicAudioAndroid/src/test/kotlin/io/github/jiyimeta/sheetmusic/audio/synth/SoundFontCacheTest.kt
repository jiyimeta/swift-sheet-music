package io.github.jiyimeta.sheetmusic.audio.synth

import android.content.res.AssetFileDescriptor
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The SoundFont cache decision, isolated from the Android glue.
 *
 * `FluidSynthDriver.materializeUriToCache` keys its cache on the URI alone
 * and used to refresh only when the cached file was missing or empty. The
 * URI string does not change when a host swaps the SoundFont behind it, so
 * a stale copy was served forever — surviving every reinstall. Real cost:
 * a device kept playing a 215 MB font two months after a 32 MB one had
 * been staged in its place, which silently invalidated a day of listening
 * tests. Comparing lengths is what makes a swap visible.
 */
class SoundFontCacheTest {

    @Test fun missingTargetIsStale() {
        assertTrue(soundFontCacheIsStale(targetExists = false, targetLength = 0, sourceLength = 100))
    }

    @Test fun emptyTargetIsStale() {
        // A crashed or truncated first copy leaves a zero-length file.
        assertTrue(soundFontCacheIsStale(targetExists = true, targetLength = 0, sourceLength = 100))
    }

    @Test fun differentLengthIsStale() {
        // The bug this exists for: same URI, different bytes behind it.
        assertTrue(
            "a source of a different size must invalidate the cache",
            soundFontCacheIsStale(targetExists = true, targetLength = 215_614_036, sourceLength = 32_319_396),
        )
    }

    @Test fun sameLengthIsFresh() {
        // The common case — do not re-copy hundreds of megabytes on every launch.
        assertFalse(
            soundFontCacheIsStale(targetExists = true, targetLength = 32_319_396, sourceLength = 32_319_396),
        )
    }

    @Test fun unknownSourceLengthKeepsTheExistingCopy() {
        // Not every content provider reports a length. Re-copying on every
        // launch to cover that would make each start pay a multi-hundred-MB
        // copy; keeping the existing copy matches the previous behavior, and
        // the length check still covers every provider that does report one.
        assertFalse(
            soundFontCacheIsStale(
                targetExists = true,
                targetLength = 32_319_396,
                sourceLength = AssetFileDescriptor.UNKNOWN_LENGTH,
            ),
        )
    }

    @Test fun unknownSourceLengthStillRefreshesAMissingOrEmptyTarget() {
        assertTrue(
            soundFontCacheIsStale(
                targetExists = false,
                targetLength = 0,
                sourceLength = AssetFileDescriptor.UNKNOWN_LENGTH,
            ),
        )
        assertTrue(
            soundFontCacheIsStale(
                targetExists = true,
                targetLength = 0,
                sourceLength = AssetFileDescriptor.UNKNOWN_LENGTH,
            ),
        )
    }
}
