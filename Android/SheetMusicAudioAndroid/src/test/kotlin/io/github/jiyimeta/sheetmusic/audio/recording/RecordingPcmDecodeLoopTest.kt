package io.github.jiyimeta.sheetmusic.audio.recording

import android.media.MediaCodec
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The decode loop ([decodeToCache]) driving a fake MediaCodec: what reaches the writer, and when the loop waits. */
class RecordingPcmDecodeLoopTest {
    /**
     * A decoder in MediaCodec's shape: [inputSlots] input buffers, each queued sample decoded in order into one output
     * buffer of its PCM from [chunks], placed at a nonzero offset in its bytes. Like AAC it holds one sample back — a
     * sample comes out only once the next one has been taken in — so the last comes out only after the end of stream
     * goes in: on the end-of-stream buffer itself when [dataOnEndOfStream], else followed by an empty one.
     *
     * Nothing runs on its own. Each output poll takes in [decodesPerPoll] queued samples first; a poll that may wait
     * takes in samples until an output appears. A wait asked for while output was ready, or while an input buffer was
     * free and the source still had samples, is needless.
     */
    private class FakeCodec(
        private val chunks: List<ShortArray>,
        private val inputSlots: Int = 4,
        private val decodesPerPoll: Int = 0,
        private val format: DecodedFormat? = null,
        private val dataOnEndOfStream: Boolean = true,
    ) : DecodeCodec {
        private class Queued(val slot: Int, val chunk: ShortArray?)
        private class Output(val index: Int, val bytes: ByteBuffer, val offset: Int, val size: Int, val end: Boolean)

        private val freeSlots = ArrayDeque((0 until inputSlots).toList())
        private val dequeuedSlots = mutableSetOf<Int>()
        private val queued = ArrayDeque<Queued>()
        private var heldBack: ShortArray? = null
        private val outputs = ArrayDeque<Output?>() // a null entry is the format change
        private val held = mutableMapOf<Int, ByteBuffer>()
        private var nextChunk = 0
        private var nextOutput = 0
        private var endIndex = -1
        private var formatAnnounced = false
        private var calls = 0

        var endOfStreamQueued = 0
        var endOfStreamReleased = false
        var callsAfterEnd = 0
        var inputDequeuesAfterEnd = 0
        var inputWaits = 0
        var waits = 0
        var needlessWaits = 0
        val waitTimeouts = mutableSetOf<Long>()
        var outputBuffers = 0
        var released = 0

        private fun call() {
            if (endOfStreamReleased) callsAfterEnd++
            if (++calls > 100_000) throw AssertionError("the loop is spinning")
        }

        private fun emit(chunk: ShortArray?, end: Boolean) {
            if (format != null && !formatAnnounced) {
                outputs.addLast(null)
                formatAnnounced = true
            }
            val floats = format?.floatSamples == true
            val offset = if (chunk == null) 0 else 12
            val size = (chunk?.size ?: 0) * if (floats) 4 else 2
            val bytes = ByteBuffer.allocate(offset + size + 8).order(ByteOrder.LITTLE_ENDIAN)
            bytes.position(offset)
            chunk?.forEach { if (floats) bytes.putFloat(it / 32767f) else bytes.putShort(it) }
            bytes.position(offset)
            bytes.limit(offset + size)
            outputs.addLast(Output(nextOutput++, bytes, offset, size, end))
        }

        /** Takes the next queued sample in, freeing its input buffer; false when none is queued. */
        private fun decodeOne(): Boolean {
            val item = queued.removeFirstOrNull() ?: return false
            freeSlots.addLast(item.slot)
            val previous = heldBack
            heldBack = item.chunk
            when {
                item.chunk != null -> previous?.let { emit(it, end = false) }
                previous != null && dataOnEndOfStream -> emit(previous, end = true)
                else -> {
                    previous?.let { emit(it, end = false) }
                    emit(null, end = true)
                }
            }
            return true
        }

        override fun dequeueInputBuffer(timeoutMicros: Long): Int {
            call()
            if (timeoutMicros > 0) inputWaits++
            if (endOfStreamQueued > 0) inputDequeuesAfterEnd++
            val slot = freeSlots.removeFirstOrNull() ?: return -1
            dequeuedSlots += slot
            return slot
        }

        override fun queueInput(index: Int): Boolean {
            call()
            check(dequeuedSlots.remove(index)) { "input buffer $index was not dequeued" }
            val chunk = chunks.getOrNull(nextChunk++)
            queued.addLast(Queued(index, chunk))
            if (chunk == null) endOfStreamQueued++
            return chunk != null
        }

        override fun dequeueOutputBuffer(info: DecodedBufferInfo, timeoutMicros: Long): Int {
            call()
            if (timeoutMicros > 0) {
                waits++
                waitTimeouts += timeoutMicros
                val inputCouldGoIn = freeSlots.isNotEmpty() && endOfStreamQueued == 0
                if (outputs.isNotEmpty() || inputCouldGoIn) needlessWaits++
            }
            repeat(decodesPerPoll) { decodeOne() }
            if (timeoutMicros > 0) {
                while (outputs.isEmpty() && decodeOne()) Unit
            }
            if (outputs.isEmpty()) return MediaCodec.INFO_TRY_AGAIN_LATER
            val output = outputs.removeFirst() ?: return MediaCodec.INFO_OUTPUT_FORMAT_CHANGED
            info.offset = output.offset
            info.size = output.size
            info.endOfStream = output.end
            held[output.index] = output.bytes
            outputBuffers++
            if (output.end) endIndex = output.index
            return output.index
        }

        override fun outputBuffer(index: Int): ByteBuffer? {
            call()
            return held[index] ?: error("output buffer $index is not held")
        }

        override fun releaseOutputBuffer(index: Int) {
            call()
            checkNotNull(held.remove(index)) { "output buffer $index released twice or never dequeued" }
            released++
            if (index == endIndex) endOfStreamReleased = true
        }

        override fun outputFormat(): DecodedFormat = format ?: error("no format change")
    }

    /** A writer collecting every sample appended, with the channel count each append came with. */
    private class FakeWriter(
        private val existingAt: Map<Double, String> = emptyMap(),
        private val appendResult: Int = 0,
    ) : RecordingPcmWriterCalls {
        var onAppend: (Int) -> Unit = {}
        val samples = mutableListOf<Short>()
        val channelCounts = mutableSetOf<Int>()
        var appends = 0
        var openedAt: Double? = null
        var finished = 0
        val cancelled = mutableListOf<Long>()

        override fun existing(directory: String, cacheKey: String, sampleRate: Double) = existingAt[sampleRate] ?: ""

        override fun open(directory: String, cacheKey: String, sampleRate: Double): Long {
            check(openedAt == null) { "opened twice" }
            openedAt = sampleRate
            return HANDLE
        }

        override fun append(writer: Long, samples: ShortArray, frameCount: Int, channels: Int): Int {
            assertEquals(HANDLE, writer)
            this.samples += samples.copyOf(frameCount * channels).toList()
            channelCounts += channels
            onAppend(++appends)
            return appendResult
        }

        override fun finish(writer: Long): String {
            assertEquals(HANDLE, writer)
            finished++
            return "/cache/take-${openedAt?.toInt()}.pcm"
        }

        override fun cancel(writer: Long) {
            cancelled += writer
        }

        companion object {
            const val HANDLE = 42L
        }
    }

    /** [count] chunks of [frames] frames of [channels] interleaved samples, the last [lastFrames] long. */
    private fun chunks(count: Int, frames: Int, channels: Int, lastFrames: Int = frames): List<ShortArray> {
        var sample = 0
        return (0 until count).map { index ->
            val length = (if (index == count - 1) lastFrames else frames) * channels
            ShortArray(length) { ((sample++ * 37) % 60_000 - 30_000).toShort() }
        }
    }

    private fun List<ShortArray>.joined(): ShortArray = flatMap { it.toList() }.toShortArray()

    private fun decode(codec: FakeCodec, writer: FakeWriter, sourceChannels: Int = 2): String = runBlocking {
        decodeToCache(codec, writer, "/cache", "take", sourceRate = 48000, sourceChannels = sourceChannels)
    }

    @Test fun `every frame the codec puts out reaches the writer, the final buffer's too`() {
        for (decodesPerPoll in 0..3) for (slots in listOf(1, 4)) for (dataOnEnd in listOf(true, false)) {
            val source = chunks(count = 25, frames = 1024, channels = 2, lastFrames = 300)
            val codec = FakeCodec(source, slots, decodesPerPoll, dataOnEndOfStream = dataOnEnd)
            val writer = FakeWriter()
            val label = "decodesPerPoll=$decodesPerPoll slots=$slots dataOnEnd=$dataOnEnd"

            assertEquals(label, "/cache/take-48000.pcm", decode(codec, writer))
            assertArrayEquals(label, source.joined(), writer.samples.toShortArray())
            assertEquals(label, setOf(2), writer.channelCounts)
            assertEquals(label, 48000.0, writer.openedAt)
            assertEquals(label, 1, writer.finished)
            assertEquals(label, emptyList<Long>(), writer.cancelled)
            assertEquals(label, codec.outputBuffers, codec.released)
        }
    }

    @Test fun `end of stream goes in once, and the loop stops at the buffer that carries it`() {
        for (dataOnEnd in listOf(true, false)) {
            val codec = FakeCodec(chunks(10, 512, 2), dataOnEndOfStream = dataOnEnd)
            decode(codec, FakeWriter())
            assertEquals(1, codec.endOfStreamQueued)
            assertEquals("no input is asked for once the end of stream is in", 0, codec.inputDequeuesAfterEnd)
            assertTrue(codec.endOfStreamReleased)
            assertEquals("nothing is called on the codec after the last buffer", 0, codec.callsAfterEnd)
        }
    }

    @Test fun `the loop waits only when neither side of the codec can move`() {
        for (decodesPerPoll in 0..3) for (slots in listOf(1, 2, 4, 8)) {
            val codec = FakeCodec(chunks(40, 1024, 2), slots, decodesPerPoll)
            decode(codec, FakeWriter())
            val label = "decodesPerPoll=$decodesPerPoll slots=$slots"
            assertEquals("$label: never waits for an input buffer", 0, codec.inputWaits)
            assertEquals("$label: never waits while output is ready or input could go in", 0, codec.needlessWaits)
            assertTrue("$label: waits with the timeout given", codec.waitTimeouts.all { it == DECODE_WAIT_MICROS })
        }
        // A codec that works only while the loop waits needs a wait per buffer, and no more.
        val slow = FakeCodec(chunks(40, 1024, 2), inputSlots = 4, decodesPerPoll = 0)
        decode(slow, FakeWriter())
        assertTrue("${slow.waits} waits for ${slow.outputBuffers} buffers", slow.waits <= slow.outputBuffers)
    }

    @Test fun `the output format sets the file's rate, float samples convert, and more channels cut to two`() {
        val stereo = chunks(6, 256, 2)
        val floats = DecodedFormat(channels = 2, sampleRate = 44100, floatSamples = true)
        val floatWriter = FakeWriter()
        assertEquals("/cache/take-44100.pcm", decode(FakeCodec(stereo, format = floats), floatWriter))
        assertEquals(44100.0, floatWriter.openedAt)
        assertArrayEquals(stereo.joined(), floatWriter.samples.toShortArray())

        // Six channels, long buffers then a short one: the reused scratch never leaks a stale frame.
        val surround = chunks(5, 300, 6, lastFrames = 7)
        val six = DecodedFormat(channels = 6, sampleRate = 48000, floatSamples = false)
        val surroundWriter = FakeWriter()
        decode(FakeCodec(surround, format = six), surroundWriter, sourceChannels = 6)
        val frontTwo = surround.flatMap { chunk -> chunk.toList().chunked(6).flatMap { it.take(2) } }
        assertArrayEquals(frontTwo.toShortArray(), surroundWriter.samples.toShortArray())
        assertEquals(setOf(2), surroundWriter.channelCounts)

        val mono = chunks(4, 100, 1)
        val monoWriter = FakeWriter()
        decode(FakeCodec(mono), monoWriter, sourceChannels = 1)
        assertArrayEquals(mono.joined(), monoWriter.samples.toShortArray())
        assertEquals("mono reaches the writer as mono, which duplicates it", setOf(1), monoWriter.channelCounts)
    }

    @Test fun `a file already there at the decoder's own rate ends the decode before anything is written`() {
        val format = DecodedFormat(channels = 2, sampleRate = 44100, floatSamples = false)
        val writer = FakeWriter(existingAt = mapOf(44100.0 to "/cache/take-44100.pcm"))
        assertEquals("/cache/take-44100.pcm", decode(FakeCodec(chunks(8, 512, 2), format = format), writer))
        assertNull(writer.openedAt)
        assertEquals(0, writer.appends)
        assertEquals(emptyList<Long>(), writer.cancelled)
    }

    @Test fun `cancelling stops between buffers, abandons the file, and surfaces as the cancellation`() {
        val writer = FakeWriter()
        val codec = FakeCodec(chunks(20, 512, 2))
        var thrown: Throwable? = null
        runBlocking {
            val job = launch {
                try {
                    decodeToCache(codec, writer, "/cache", "take", sourceRate = 48000, sourceChannels = 2)
                } catch (e: Throwable) {
                    thrown = e
                    throw e
                }
            }
            writer.onAppend = { if (it == 3) job.cancel() }
            job.join()
        }
        assertTrue("got $thrown", thrown is CancellationException)
        assertEquals("the buffer being written when the cancel came is the last", 3, writer.appends)
        assertEquals(listOf(FakeWriter.HANDLE), writer.cancelled)
        assertEquals(0, writer.finished)
    }

    @Test fun `a recording that decodes to nothing fails, leaving nothing behind`() {
        val writer = FakeWriter()
        try {
            decode(FakeCodec(emptyList()), writer)
            fail("decoded nothing without failing")
        } catch (e: RecordingPcmDecoder.DecodeException) {
            assertEquals("the recording decodes to nothing", e.message)
        }
        assertNull(writer.openedAt)
        assertEquals(emptyList<Long>(), writer.cancelled)
    }

    @Test fun `a failed write abandons the file`() {
        val writer = FakeWriter(appendResult = -1)
        try {
            decode(FakeCodec(chunks(4, 256, 2)), writer)
            fail("a failed write went unnoticed")
        } catch (e: RecordingPcmDecoder.DecodeException) {
            assertEquals("cannot write the cache file", e.message)
        }
        assertEquals(1, writer.appends)
        assertEquals(listOf(FakeWriter.HANDLE), writer.cancelled)
        assertEquals(0, writer.finished)
    }

    @Test fun `a codec failure is a decode failure, and a cancellation stays a cancellation`() {
        val failure = IllegalStateException("codec")
        try {
            reportingCodecFailures { throw failure }
        } catch (e: RecordingPcmDecoder.DecodeException) {
            assertSame(failure, e.cause)
        }
        val cancellation = CancellationException("cancelled")
        try {
            reportingCodecFailures { throw cancellation }
        } catch (e: CancellationException) {
            assertSame(cancellation, e)
        }
    }
}
