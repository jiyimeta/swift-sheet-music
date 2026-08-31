import SheetMusicCore
import SheetMusicFoundation

extension Chord {
    /// This chord's grace chords in the order MuseScore Studio writes
    /// them into the `<voice>` stream.
    ///
    /// MuseScore stores every grace of a chord — before *and* after
    /// type — in one ordered vector (`Chord::m_graceNotes`, "storage
    /// for all grace notes", `dom/chord.h:230,410`) and its writer
    /// emits that whole vector **ahead of** the parent chord's own
    /// `<Chord>` node (`TWrite::write(const Chord*, …)`,
    /// `rw/write/twrite.cpp:980-982`, iterating `Chord::graceNotes()`).
    /// Its reader is the exact mirror: it buffers every consecutive
    /// grace-type `<Chord>` and attaches the *whole run* to the next
    /// normal chord (`MeasureRead::readVoice`,
    /// `rw/read460/measureread.cpp:261-286`). File position therefore
    /// never decides which chord a grace belongs to, and never decides
    /// whether it is a before- or an after-grace — only the grace-type
    /// tag does. Confirmed against genuine MuseScore fixtures, where a
    /// `<grace8after/>` sits ahead of the very first chord of its
    /// measure (`midi/midirenderer_data/grace_after.mscx:146-164` in
    /// the upstream engraving test resources) — a position no
    /// "after-graces follow their owner" reading can explain.
    ///
    /// The split back out of that single vector is asymmetric:
    /// `Chord::graceNotesBefore()` filters it **forward**
    /// (`dom/chord.cpp:2135-2154`) while `Chord::graceNotesAfter()`
    /// filters it **in reverse** (`:2160-2175`). So an after-grace run
    /// is stored — and written — back-to-front relative to the order it
    /// sounds in. Verified end-to-end against an upstream playback
    /// test rather than inferred from the C++ alone:
    /// `playback/playbackeventsrenderer_data/single_note_multi_appoggiatura_post`
    /// writes `<grace32after/>` A4 then `<grace16after/>` G4 ahead of
    /// its F4 main chord, and
    /// `Engraving_PlaybackEventsRendererTests.SingleNote_MultiAppoggiatura_Post`
    /// (`tests/playback/playbackeventsrendering_tests.cpp:1667`) expects
    /// them to sound F4 → G4 → A4 — i.e. reverse file order.
    ///
    /// `Chord.graceNotesAfter` in this project is the *sounding* order
    /// (`MidiRenderer+Grace.swift` plays it front-to-back,
    /// `LayoutEngine+Placement.swift` draws it left-to-right), matching
    /// `Chord::graceNotesAfter()`, so it is reversed on the way out.
    ///
    /// Where MuseScore's own vector *interleaves* the two types — its
    /// order is edit-history dependent, since `Chord::add`
    /// (`dom/chord.cpp:689-696`) inserts a newly created grace at
    /// `graceIndex()`, which is `0` for a fresh one — this project
    /// cannot reproduce the interleaving: the model keeps two separate
    /// lists and no file-order index. Re-encoding such a file groups
    /// the two runs instead. That is semantically identical on reload
    /// (MuseScore splits by tag, not position) but not byte-identical.
    var mscxFileOrderedGraces: [GraceChord] {
        graceNotesBefore + graceNotesAfter.reversed()
    }

    /// `mscxFileOrderedGraces` paired with each grace's index in the list it
    /// came from — `graceNotesBefore` or `graceNotesAfter`, both in *sounding*
    /// order. A guitar bend chains from one grace of a run to the next, so the
    /// encoder needs that index to name a grace's neighbour; file order alone
    /// runs an after-grace run backwards. See
    /// `GraceChord.guitarBendForwardEndpoint`.
    var mscxFileOrderedGracesWithListIndex: [(grace: GraceChord, listIndex: Int)] {
        graceNotesBefore.enumerated().map { ($0.element, $0.offset) }
            + graceNotesAfter.enumerated().reversed().map { ($0.element, $0.offset) }
    }

    /// The `<grace>N</grace>` ordinal of `graceNotesBefore[index]` —
    /// MuseScore's `Location::graceIndex` (`dom/location.cpp:199-208`),
    /// which is `Chord::graceIndex()`, assigned by the reader from the
    /// grace's position within the file run
    /// (`rw/read460/measureread.cpp:275-279`). Before-graces lead
    /// `mscxFileOrderedGraces`, so the ordinal is the index itself.
    func mscxGraceIndex(ofBeforeGraceAt index: Int) -> Int {
        index
    }

    /// The `<grace>N</grace>` ordinal of `graceNotesAfter[index]`.
    /// After-graces trail the before-graces in `mscxFileOrderedGraces`
    /// and are written in reverse sounding order, so the ordinal counts
    /// back from the end of the run.
    func mscxGraceIndex(ofAfterGraceAt index: Int) -> Int {
        graceNotesBefore.count + (graceNotesAfter.count - 1 - index)
    }
}
