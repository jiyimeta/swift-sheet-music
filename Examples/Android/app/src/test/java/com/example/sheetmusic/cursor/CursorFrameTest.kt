package com.example.sheetmusic.cursor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class CursorFrameTest {

    @Test
    fun decodesGoldenPayload() {
        // CGRect(x: 10.5, y: 20.0, width: 4.0, height: 80.5) in document coords.
        // Encoded as raw IEEE 754 f64 (little-endian), 32 bytes total.
        // Wire format changed in afea8bf: version envelope + micros dropped in
        // favour of raw f64 to match the @WireFormat-generated CursorFrameCodec.
        val bytes = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN).apply {
            putDouble(10.5)
            putDouble(20.0)
            putDouble(4.0)
            putDouble(80.5)
        }.array()

        val frame = CursorFrame.decode(bytes)!!

        assertEquals(10.5, frame.x, 1e-9)
        assertEquals(20.0, frame.y, 1e-9)
        assertEquals(4.0, frame.width, 1e-9)
        assertEquals(80.5, frame.height, 1e-9)
    }

    @Test
    fun emptyDecodesToNull() {
        assertNull(CursorFrame.decode(byteArrayOf()))
    }

    @Test(expected = IllegalArgumentException::class)
    fun shortPayloadThrows() {
        val bytes = ByteArray(10) { it.toByte() }
        CursorFrame.decode(bytes)
    }
}
