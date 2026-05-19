package io.github.kiichiio.sheetmusic.audio.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorEqualityTest {
    private val staff = StaffAddress(partIndex = 0, staffIndexInPart = 0)
    private val voiceElemID = VoiceElementID(staff = staff, measureIndex = 1, voiceIndex = 0, elementIndex = 2)

    @Test fun noteIDEquality() {
        val a = NoteID(staff = staff, measureIndex = 1, voiceIndex = 0, elementIndex = 2, noteIndexInChord = 0)
        val b = NoteID(staff = staff, measureIndex = 1, voiceIndex = 0, elementIndex = 2, noteIndexInChord = 0)
        assertEquals(a, b)
        assertTrue(a.toString().contains("NoteID"))
    }

    @Test fun restIDEquality() {
        val a = RestID(staff = staff, measureIndex = 2, voiceIndex = 1, elementIndex = 0)
        val b = RestID(staff = staff, measureIndex = 2, voiceIndex = 1, elementIndex = 0)
        assertEquals(a, b)
        assertTrue(a.toString().contains("RestID"))
    }

    @Test fun tupletIDEquality() {
        val a = TupletID(staff = staff, measureIndex = 3, voiceIndex = 0, startElementIndex = 4)
        val b = TupletID(staff = staff, measureIndex = 3, voiceIndex = 0, startElementIndex = 4)
        assertEquals(a, b)
        assertTrue(a.toString().contains("TupletID"))
    }

    @Test fun clefAnchorExplicitEquality() {
        val a = ClefAnchor.Explicit(voiceElementID = voiceElemID)
        val b = ClefAnchor.Explicit(voiceElementID = voiceElemID)
        assertEquals(a, b)
        assertTrue(a.toString().contains("Explicit"))
    }

    @Test fun clefAnchorStaffDefaultEquality() {
        val a = ClefAnchor.StaffDefault(staff = staff)
        val b = ClefAnchor.StaffDefault(staff = staff)
        assertEquals(a, b)
        assertTrue(a.toString().contains("StaffDefault"))
    }

    @Test fun scoreCursorItemEquality() {
        val noteID = NoteID(staff = staff, measureIndex = 0, voiceIndex = 0, elementIndex = 0, noteIndexInChord = 0)
        val a = ScoreCursor.Item(item = ScoreItemID.Note(id = noteID))
        val b = ScoreCursor.Item(item = ScoreItemID.Note(id = noteID))
        assertEquals(a, b)
        assertTrue(a.toString().contains("Item"))
    }

    @Test fun scoreCursorBeatEquality() {
        val a = ScoreCursor.Beat(measureIndex = 5, tickInMeasure = 480)
        val b = ScoreCursor.Beat(measureIndex = 5, tickInMeasure = 480)
        assertEquals(a, b)
        assertTrue(a.toString().contains("Beat"))
    }
}
