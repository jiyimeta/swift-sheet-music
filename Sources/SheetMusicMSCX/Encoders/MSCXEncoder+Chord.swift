import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// Encode as a `<Chord>` (notes-bearing). Caller must guarantee
    /// `notes.isEmpty == false`; voice-level dispatch routes empty
    /// chords through `encodeAsRest()` instead.
    ///
    /// `tieForwardLocation` / `tieBackLocation` describe the
    /// `<Spanner type="Tie"><location>` payload for ties on this
    /// chord. `Voice.encode` decides which form to use based on
    /// whether the partner chord lives in the same measure or
    /// crosses the bar line.
    func encodeAsChord(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        let isPercussionV3 =
            options.targetVersion == .v3 && staffGroup == "percussion"
        if isPercussionV3 {
            // MuseScore 3 drum-track chords carry an explicit
            // `<StemDirection>` element ahead of `<durationType>` —
            // voice 0 stems up, voice 1+ stems down (DrumStaff
            // convention from MS3 `Chord::write`).
            children.append(XMLTreeNode(
                name: "StemDirection",
                text: voiceIndex == 0 ? "up" : "down",
            ))
        }
        duration.appendDurationXML(to: &children)
        // Articulations sit between durationType and the first
        // <Lyrics>/<Note>: matches MuseScore's Chord::write ordering
        // and is accepted by both MS3 (3.6.2+) and MS4 readers. C++:
        //   engraving/dom/chord.cpp Chord::write — durationType →
        //   StemDirection → ChordLine / Articulation / Tremolo →
        //   Lyrics → Note.
        for art in articulations {
            children.append(art.encode(options: options))
        }
        // Lyrics sit between durationType and the first <Note>: this
        // matches MuseScore's serializer (Chord::write) and is what
        // both MS3 and MS4 readers expect. Empty-text placeholders
        // (verse-padding entries inserted by the decoder when verse N
        // exists without verse N-1) are skipped — emitting them
        // produces stray empty syllables on screen.
        for lyric in lyrics where !lyric.text.isEmpty {
            children.append(lyric.encode(options: options))
        }
        for note in notes {
            children.append(note.encode(
                tieForwardLocation: tieForwardLocation,
                tieBackLocation: tieBackLocation,
                options: options,
                drumDefaultHead: isPercussionV3 ? "normal" : nil,
            ))
        }
        return XMLTreeNode(name: "Chord", children: children)
    }

    /// Encode as a `<Rest>` (notes-empty representation).
    func encodeAsRest(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        return XMLTreeNode(name: "Rest", children: children)
    }
}
