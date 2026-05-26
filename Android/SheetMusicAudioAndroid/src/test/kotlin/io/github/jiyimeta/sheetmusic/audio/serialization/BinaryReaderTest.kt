package io.github.jiyimeta.sheetmusic.audio.serialization

import io.github.jiyimeta.wirelet.BinaryReader
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class BinaryReaderTest {

    @Test
    fun readU8_singleByte() {
        val r = BinaryReader(byteArrayOf(0x42))
        assertEquals(0x42, r.readU8().toInt())
        assertEquals(0, r.remaining)
    }

    @Test
    fun readU8_maxValue() {
        val r = BinaryReader(byteArrayOf(0xFF.toByte()))
        assertEquals(255, r.readU8().toInt())
    }

    @Test
    fun readU8_underflow() {
        val r = BinaryReader(byteArrayOf())
        try {
            r.readU8()
            fail("Expected UnderflowException")
        } catch (_: BinaryReader.UnderflowException) {
            // expected
        }
    }

    @Test
    fun readU16_littleEndian() {
        // 0xABCD in LE is 0xCD, 0xAB
        val r = BinaryReader(byteArrayOf(0xCD.toByte(), 0xAB.toByte()))
        assertEquals(0xABCD, r.readU16())
    }

    @Test
    fun readU16_version1() {
        val r = BinaryReader(byteArrayOf(0x01, 0x00))
        assertEquals(1, r.readU16())
    }

    @Test
    fun readI32_positiveValue() {
        // 480 = 0x000001E0 → LE bytes: E0 01 00 00
        val r = BinaryReader(byteArrayOf(0xE0.toByte(), 0x01, 0x00, 0x00))
        assertEquals(480, r.readI32())
    }

    @Test
    fun readI32_negativeOne() {
        // -1 = 0xFFFFFFFF → LE bytes: FF FF FF FF
        val r = BinaryReader(byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte()))
        assertEquals(-1, r.readI32())
    }

    @Test
    fun readI32_zero() {
        val r = BinaryReader(byteArrayOf(0x00, 0x00, 0x00, 0x00))
        assertEquals(0, r.readI32())
    }

    @Test
    fun readI64_value480() {
        // 480L → LE 8 bytes: E0 01 00 00 00 00 00 00
        val r = BinaryReader(byteArrayOf(0xE0.toByte(), 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        assertEquals(480L, r.readI64())
    }

    @Test
    fun readI64_timeMicros1500000() {
        // 1_500_000 = 0x16_E360 → LE: 60 E3 16 00 00 00 00 00
        val r = BinaryReader(byteArrayOf(0x60, 0xE3.toByte(), 0x16, 0x00, 0x00, 0x00, 0x00, 0x00))
        assertEquals(1_500_000L, r.readI64())
    }

    @Test
    fun readI64_negativeOne() {
        // -1L = 0xFFFFFFFFFFFFFFFF
        val bytes = ByteArray(8) { 0xFF.toByte() }
        val r = BinaryReader(bytes)
        assertEquals(-1L, r.readI64())
    }

    @Test
    fun remainingDecrementsCorrectly() {
        val r = BinaryReader(byteArrayOf(0x01, 0x02, 0x03, 0x04))
        assertEquals(4, r.remaining)
        r.readU8()
        assertEquals(3, r.remaining)
        r.readU16()
        assertEquals(1, r.remaining)
        r.readU8()
        assertEquals(0, r.remaining)
    }
}
