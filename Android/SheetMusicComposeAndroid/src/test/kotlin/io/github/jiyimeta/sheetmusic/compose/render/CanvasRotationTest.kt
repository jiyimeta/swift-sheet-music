package io.github.jiyimeta.sheetmusic.compose.render

import org.junit.Assert.assertEquals
import org.junit.Test

class CanvasRotationTest {
    /**
     * A canvas save stack, with the degrees rotated inside each saved layer. Android counts the base layer as save
     * count 1, `save` returns the count from before it pushed, and `restoreToCount(n)` pops until the count is `n`.
     */
    private class RecordingCanvas : CanvasRotation.Target {
        val layers = ArrayList<Float>()
        private val count get() = 1 + layers.size

        /** The rotation a draw issued now would be transformed by. */
        val degreesInForce get() = layers.sum()

        override fun save(): Int = count.also { layers.add(0f) }

        override fun rotate(degrees: Float, pivotX: Float, pivotY: Float) {
            layers[layers.lastIndex] += degrees
        }

        override fun restoreToCount(saveCount: Int) {
            while (count > saveCount) layers.removeAt(layers.lastIndex)
        }
    }

    @Test
    fun `a rotation replaces the one in force instead of stacking on it`() {
        // A wavy glissando's shape: one rotation per wiggle, each about its own pivot, and one reset after the run.
        val canvas = RecordingCanvas()
        val rotation = CanvasRotation()
        val angle = Math.toRadians(10.0)
        for (wiggle in 0 until 5) {
            rotation.set(canvas, angle, pivotXPx = 10f * wiggle, pivotYPx = 0f)
            assertEquals("one layer open at wiggle $wiggle", 1, canvas.layers.size)
            assertEquals("degrees in force at wiggle $wiggle", 10f, canvas.degreesInForce, 1e-4f)
        }
        rotation.set(canvas, 0.0, 0f, 0f)
        assertEquals("nothing open after the reset", 0, canvas.layers.size)
    }

    @Test
    fun `a reset with no rotation open leaves the canvas alone`() {
        val canvas = RecordingCanvas()
        val rotation = CanvasRotation()
        canvas.save()
        rotation.set(canvas, 0.0, 0f, 0f)
        assertEquals(1, canvas.layers.size)
    }

    @Test
    fun `closing restores a rotation the run left open, once`() {
        val canvas = RecordingCanvas()
        val rotation = CanvasRotation()
        rotation.set(canvas, Math.toRadians(30.0), 0f, 0f)
        rotation.close(canvas)
        assertEquals(0, canvas.layers.size)
        // A second close finds nothing open, so a host layer saved after the first stays put.
        canvas.save()
        rotation.close(canvas)
        assertEquals(1, canvas.layers.size)
    }
}
