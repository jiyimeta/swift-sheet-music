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
        // Encoded as micros (little-endian i64):
        //   10.5  * 1e6 = 10_500_000 = 0x00_00_00_00_00_A0_36_A0
        //   20.0  * 1e6 = 20_000_000 = 0x00_00_00_00_01_31_2D_00
        //    4.0  * 1e6 =  4_000_000 = 0x00_00_00_00_00_3D_09_00
        //   80.5  * 1e6 = 80_500_000 = 0x00_00_00_00_04_CC_36_A0
        val bytes = ByteBuffer.allocate(34).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(1)                        // u16 version
            putLong(10_500_000L)               // x micros
            putLong(20_000_000L)               // y micros
            putLong(4_000_000L)                // width micros
            putLong(80_500_000L)               // height micros
        }.array()

        val frame = CursorFrame.decode(bytes)!!

        assertEquals(10.5, frame.x, 1e-6)
        assertEquals(20.0, frame.y, 1e-6)
        assertEquals(4.0, frame.width, 1e-6)
        assertEquals(80.5, frame.height, 1e-6)
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

    @Test(expected = IllegalArgumentException::class)
    fun wrongVersionThrows() {
        val bytes = ByteBuffer.allocate(34).order(ByteOrder.LITTLE_ENDIAN).apply {
            putShort(99)    // wrong version
            putLong(0L); putLong(0L); putLong(0L); putLong(0L)
        }.array()
        CursorFrame.decode(bytes)
    }
}
