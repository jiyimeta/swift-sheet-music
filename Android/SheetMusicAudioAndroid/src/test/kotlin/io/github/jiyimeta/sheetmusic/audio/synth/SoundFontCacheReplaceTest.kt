package io.github.jiyimeta.sheetmusic.audio.synth

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.file.Files

/**
 * A stale `sf2-cache` copy is replaced by a new file renamed over it, never rewritten in place: a synth, an export or a
 * prefetch may still have the old file memory-mapped, and truncating it under the mapping makes the render thread's
 * next read of a vanished page a SIGBUS.
 */
class SoundFontCacheReplaceTest {

    @Test fun aStaleCopyIsReplacedByANewFileAndAnOpenMappingKeepsTheOldBytes() {
        val dir = Files.createTempDirectory("sf2-cache").toFile()
        try {
            val target = File(dir, "sf-1.sf2")
            val old = ByteArray(8192) { 1 }
            target.writeBytes(old)
            val oldKey = Files.readAttributes(target.toPath(), "unix:ino")["ino"]
            RandomAccessFile(target, "r").use { file ->
                val mapping = file.channel.map(FileChannel.MapMode.READ_ONLY, 0, old.size.toLong())

                replaceFileAtomically(target) { it.write(ByteArray(16) { 2 }) }

                // The mapped file was not truncated: every old page is still there.
                val stillMapped = ByteArray(old.size).also { mapping.get(it) }
                assertArrayEquals(old, stillMapped)
            }
            assertArrayEquals(ByteArray(16) { 2 }, target.readBytes())
            assertNotEquals("a new file took the name", oldKey, Files.readAttributes(target.toPath(), "unix:ino")["ino"])
            assertEquals("no temporary file is left behind", listOf("sf-1.sf2"), dir.list()!!.toList())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun aFailedWriteLeavesTheOldCopyAndNoTemporaryFile() {
        val dir = Files.createTempDirectory("sf2-cache").toFile()
        try {
            val target = File(dir, "sf-1.sf2")
            target.writeBytes(ByteArray(4) { 1 })

            val failed = runCatching { replaceFileAtomically(target) { throw java.io.IOException("source gone") } }

            assertFalse(failed.isSuccess)
            assertArrayEquals(ByteArray(4) { 1 }, target.readBytes())
            assertEquals(listOf("sf-1.sf2"), dir.list()!!.toList())
        } finally {
            dir.deleteRecursively()
        }
    }
}
