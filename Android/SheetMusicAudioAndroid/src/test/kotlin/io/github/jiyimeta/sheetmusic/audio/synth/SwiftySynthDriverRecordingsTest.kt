package io.github.jiyimeta.sheetmusic.audio.synth

import io.github.jiyimeta.sheetmusic.audio.model.PlaybackAlignment
import io.github.jiyimeta.sheetmusic.audio.model.PlaybackTimeWarpSpan
import io.github.jiyimeta.sheetmusic.audio.model.RecordingSegment
import io.github.jiyimeta.sheetmusic.audio.model.RecordingTrack
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import kotlin.concurrent.thread

/** What [SwiftySynthDriver] sends the recording entry points (`RecordingBridge.swift`), against stand-in natives. */
class SwiftySynthDriverRecordingsTest {
    private class Natives : SynthNativeCalls {
        val calls: MutableList<String> = Collections.synchronizedList(mutableListOf())
        var commitResult = 0
        var alignmentResult = 0
        var speed = 0.0
        /** What `nativeRenderMix` answers; null answers the frames asked for. */
        var renderResult: Int? = null
        /** Runs inside `recordingsCommit`, where the real one maps the tracks' files and makes their stretchers. */
        var duringCommit: (() -> Unit)? = null
        /** Runs inside `nativeRenderMix`, where the real one renders a block. */
        var duringRender: (() -> Unit)? = null

        override fun synthRelease(handle: Long) { calls += "release($handle)" }
        override fun synthLoadSoundFont(handle: Long, path: String) = 0
        override fun synthProgramSelect(handle: Long, channel: Int, bank: Int, program: Int) {}
        override fun synthControlChange(handle: Long, channel: Int, controller: Int, value: Int) {}
        override fun synthControllerValue(handle: Long, channel: Int, controller: Int) = 0
        override fun synthSetGain(handle: Long, gain: Float) {}
        override fun synthNoteOn(handle: Long, channel: Int, key: Int, velocity: Int) {}
        override fun synthNoteOff(handle: Long, channel: Int, key: Int) {}
        override fun synthPitchBend(handle: Long, channel: Int, value: Int) {}
        override fun synthAllNotesOff(handle: Long, channel: Int) {}
        override fun nativeRender(handle: Long, frames: Int, left: FloatArray, right: FloatArray) = frames
        override fun sequenceCreate(synthHandle: Long, smf: ByteArray) = 0L

        override fun nativeRenderMix(
            scoreHandle: Long, metronomeHandle: Long, metronomeAudible: Boolean, frames: Int,
            left: FloatArray, right: FloatArray, metronomeLeft: FloatArray, metronomeRight: FloatArray,
        ): Int {
            calls += "renderMix($scoreHandle,$metronomeHandle,$metronomeAudible,$frames)"
            duringRender?.invoke()
            return renderResult ?: frames
        }
        override fun recordingsClear(handle: Long) { calls += "clear($handle)" }
        override fun recordingsStage(
            handle: Long, id: String, pcmPath: String, offsetSeconds: Double, transposeSemitones: Int, volume: Double,
            muted: Boolean, soloed: Boolean,
        ) { calls += "stage($id,$pcmPath,$offsetSeconds,$transposeSemitones,$volume,$muted,$soloed)" }
        override fun recordingsCommit(handle: Long, soloing: Boolean, readerTransposeSemitones: Int): Int {
            calls += "commit($soloing,$readerTransposeSemitones)"
            duringCommit?.invoke()
            return commitResult
        }
        override fun alignmentClear(handle: Long) { calls += "alignmentClear" }
        override fun alignmentAddSpan(handle: Long, start: Double, end: Double, duration: Double) {
            calls += "span($start,$end,$duration)"
        }
        override fun alignmentAddSegment(
            handle: Long, trackId: String, sourceStart: Double, sourceEnd: Double, outputStart: Double,
        ) { calls += "segment($trackId,$sourceStart,$sourceEnd,$outputStart)" }
        override fun alignmentCommit(handle: Long): Int {
            calls += "alignmentCommit"
            return alignmentResult
        }
        override fun countInDuration(handle: Long, seconds: Double) = seconds * 2
        override fun countInSpeed(handle: Long, seconds: Double) = speed
        override fun setTransportScore(handle: Long, scoreHandle: Long) { calls += "transportScore($handle,$scoreHandle)" }
        override fun notatedSecondsAtOutput(handle: Long, seconds: Double): Double {
            calls += "notated($handle,$seconds)"
            return seconds - 1
        }
        override fun outputSecondsAtNotated(handle: Long, seconds: Double): Double {
            calls += "output($handle,$seconds)"
            return seconds + 1
        }
    }

    @Test fun `a track list is staged in order and committed with the bus and the reader's transposition`() {
        val natives = Natives()
        val driver = SwiftySynthDriver(7L, natives)
        val ok = driver.setRecordingTracks(
            listOf(RecordingTrack("a", "/a.pcm", 1.5, 2, 0.5f, false, true), RecordingTrack("b", "/b.pcm")),
            soloing = true, readerTransposeSemitones = -1,
        )
        assertTrue(ok)
        assertEquals(
            listOf(
                "clear(7)", "stage(a,/a.pcm,1.5,2,0.5,false,true)", "stage(b,/b.pcm,0.0,0,1.0,false,false)",
                "commit(true,-1)",
            ),
            natives.calls,
        )
        natives.commitResult = -1
        assertFalse("a file that does not map is a failure", driver.setRecordingTracks(emptyList(), false, 0))
    }

    @Test fun `an alignment is staged span by span and segment by segment, the shared table under the empty id`() {
        val natives = Natives()
        val driver = SwiftySynthDriver(7L, natives)
        val ok = driver.setAlignment(
            PlaybackAlignment(
                warpSpans = listOf(PlaybackTimeWarpSpan(0.0, 2.0, 4.0)),
                segments = listOf(RecordingSegment(0.0, 10.0, 0.0)),
                trackSegments = mapOf("b" to listOf(RecordingSegment(1.0, 3.0, 5.0))),
            ),
        )
        assertTrue(ok)
        assertEquals(
            listOf(
                "alignmentClear", "span(0.0,2.0,4.0)", "segment(,0.0,10.0,0.0)", "segment(b,1.0,3.0,5.0)",
                "alignmentCommit",
            ),
            natives.calls,
        )
        natives.alignmentResult = -1
        assertFalse(driver.setAlignment(PlaybackAlignment()))
    }

    @Test fun `renderMix passes the metronome's handle, and none once it is closed`() {
        val natives = Natives()
        val score = SwiftySynthDriver(7L, natives)
        val click = SwiftySynthDriver(9L, natives)
        val buffers = List(4) { FloatArray(480) }
        assertTrue(score.renderMix(click, true, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        click.close()
        assertTrue(score.renderMix(click, true, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        assertEquals(listOf("renderMix(7,9,true,480)", "release(9)", "renderMix(7,0,false,480)"), natives.calls)
        score.close()
        assertFalse("a closed score synth renders nothing", score.renderMix(null, false, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
    }

    /** Runs [body] on another thread and answers whether it finished within two seconds — false: it waited on a lock. */
    private fun finishesElsewhere(body: () -> Unit): Boolean {
        val other = thread(isDaemon = true) { body() }
        other.join(2_000)
        return !other.isAlive
    }

    @Test fun `a track list commits without holding up the render`() {
        val natives = Natives()
        val score = SwiftySynthDriver(7L, natives)
        val click = SwiftySynthDriver(9L, natives)
        val buffers = List(4) { FloatArray(480) }
        var rendered = false
        natives.duringCommit = {
            rendered = finishesElsewhere {
                score.renderMix(click, true, 480, buffers[0], buffers[1], buffers[2], buffers[3])
            }
        }
        assertTrue(score.setRecordingTracks(listOf(RecordingTrack("a", "/a.pcm")), soloing = false, 0))
        assertTrue("the writer thread renders a block while the files map", rendered)
    }

    @Test fun `a render holds up no control call, a clock read or an alignment`() {
        val natives = Natives()
        val driver = SwiftySynthDriver(7L, natives)
        val buffers = List(4) { FloatArray(480) }
        var answered = false
        natives.duringRender = {
            answered = finishesElsewhere {
                driver.currentOutputSeconds()
                driver.setAlignment(PlaybackAlignment(warpSpans = listOf(PlaybackTimeWarpSpan(0.0, 2.0, 4.0))))
                driver.prefetchRecordings(-1L)
            }
        }
        assertTrue(driver.renderMix(null, false, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        assertTrue(answered)
    }

    @Test fun `after close neither a render nor a control call reaches the handle`() {
        val natives = Natives()
        val driver = SwiftySynthDriver(7L, natives)
        val buffers = List(4) { FloatArray(480) }
        assertTrue(driver.renderMix(null, false, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        assertTrue(driver.setAlignment(PlaybackAlignment()))
        driver.close()
        assertFalse(driver.renderMix(null, false, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        assertFalse(driver.setAlignment(PlaybackAlignment()))
        assertEquals(1, natives.calls.count { it.startsWith("release") })
    }

    @Test fun `renderMix fails when the native render left the arrays untouched`() {
        val natives = Natives()
        val score = SwiftySynthDriver(7L, natives)
        val click = SwiftySynthDriver(9L, natives)
        val buffers = List(4) { FloatArray(480) }
        natives.renderResult = 0
        assertFalse(score.renderMix(click, true, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        assertFalse("alone too", score.renderMix(null, false, 480, buffers[0], buffers[1], buffers[2], buffers[3]))
        natives.renderResult = 479
        assertFalse(
            "a short render is not a block",
            score.renderMix(null, false, 480, buffers[0], buffers[1], buffers[2], buffers[3]),
        )
    }

    @Test fun `the notated clock goes to the synth's handle, and is NaN once it is closed`() {
        val natives = Natives()
        val driver = SwiftySynthDriver(7L, natives)
        driver.setTransportScore(42L)
        assertEquals(2.0, driver.notatedSecondsAtOutput(3.0), 0.0)
        assertEquals(4.0, driver.outputSecondsAtNotated(3.0), 0.0)
        assertEquals(listOf("transportScore(7,42)", "notated(7,3.0)", "output(7,3.0)"), natives.calls)

        driver.close()
        driver.setTransportScore(43L)
        assertTrue(driver.notatedSecondsAtOutput(3.0).isNaN())
        assertTrue(driver.outputSecondsAtNotated(3.0).isNaN())
        assertEquals("nothing reaches a released handle", listOf("release(7)"), natives.calls.drop(3))
    }

    @Test fun `a count-in reports the warped speed, or none`() {
        val natives = Natives()
        val driver = SwiftySynthDriver(7L, natives)
        assertNull(driver.countIn(2.0)!!.speed)
        natives.speed = 0.5
        val timing = driver.countIn(2.0)!!
        assertEquals(0.5, timing.speed!!, 1e-12)
        assertEquals(4.0, timing.durationSeconds, 1e-12)
    }
}
