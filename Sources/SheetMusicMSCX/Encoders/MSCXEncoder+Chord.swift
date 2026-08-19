import SheetMusicCore
import SheetMusicFoundation
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
    /// crosses the bar line. A note whose tie actually targets one of
    /// this chord's own graces overrides the corresponding argument
    /// per-note — see `graceBeforeTieBackEndpoints()` and
    /// `graceAfterTieForwardEndpoints()`.
    func encodeAsChord(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        tieForwardPartnerNotes: ChordNotes? = nil,
        tieBackPartnerNotes: ChordNotes? = nil,
        options: MSCXEncoderOptions = .init(),
        staffGroup: String = "pitched",
        voiceIndex: Int = 0,
        injectedTremolo: Tremolo? = nil,
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
        // Chord-level `<ChordLine>`s lead the cluster; the ones bound to
        // a specific note (`noteIndex != nil`) are written inside that
        // `<Note>` instead — see the `chordLines:` argument below. A
        // `noteIndex` pointing past the note list (possible when
        // `ChordNotes` deduped a repeated pitch after decode) demotes to
        // the chord-level form rather than dropping the element.
        for line in chordLines where !notes.indices.contains(line.noteIndex ?? -1) {
            children.append(line.encode(options: options))
        }
        for art in articulations {
            children.append(art.encode(options: options))
        }
        // Tremolo sits with the ChordLine / Articulation cluster — after
        // articulations and before Lyrics / Note. For two-chord tremolo
        // (`span == .between`) the follower carries `tremolo == nil`
        // on the model; the voice-level encoder threads the start's
        // tremolo through `injectedTremolo` so MuseScore can round-trip
        // read both `<Tremolo>` blocks back to a pair.
        if let trem = tremolo ?? injectedTremolo {
            children.append(trem.encodeXML())
        }
        // Stem properties (`<Stem><visible>0</visible></Stem>`) sit
        // before Lyrics/Notes, matching MuseScore's `Chord::write`
        // ordering and the position in MS4-authored fixtures. Emitted
        // only when the stem is hidden — the default (visible) omits
        // the tag entirely.
        if !stemVisible {
            children.append(XMLTreeNode(name: "Stem", children: [
                XMLTreeNode(name: "visible", text: "0"),
            ]))
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
        // Per-note overrides for a tie whose partner is one of this
        // chord's own graces rather than the neighbouring real chord
        // the `tieForwardLocation` / `tieBackLocation` arguments were
        // computed against — see `graceBeforeTieBackEndpoints()` and
        // `graceAfterTieForwardEndpoints()`. Both are empty whenever
        // this chord has no grace-tie partner, so a chord without
        // graces (or whose graces carry no matching tie) takes the
        // fallback on every note and this loop's output is unchanged.
        let graceTieBackOverrides = graceBeforeTieBackEndpoints()
        let graceTieForwardOverrides = graceAfterTieForwardEndpoints()
        for (noteIndex, note) in notes.enumerated() {
            children.append(note.encode(
                tieForwardEndpoint: graceTieForwardOverrides[noteIndex]
                    ?? tieForwardLocation.map {
                        TieEndpoint($0, notesDelta: notesDelta(
                            forPitch: note.pitch, partner: tieForwardPartnerNotes,
                        ))
                    },
                tieBackEndpoint: graceTieBackOverrides[noteIndex]
                    ?? tieBackLocation.map {
                        TieEndpoint($0, notesDelta: notesDelta(
                            forPitch: note.pitch, partner: tieBackPartnerNotes,
                        ))
                    },
                options: options,
                drumDefaultHead: isPercussionV3 ? "normal" : nil,
                chordLines: chordLines.filter { $0.noteIndex == noteIndex },
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Chord", children: children)
    }

    /// The `<notes>` half of an ordinary chord-to-chord tie's
    /// `<location>`: `Location::note(partner) − Location::note(self)`.
    /// A tie's two notes always share a pitch, so the partner is found
    /// by pitch; both indices are ranks by pitch within their own chord
    /// (`MSCXLocationNoteIndex`). Zero — and so elided — whenever both
    /// chords give that pitch the same rank, which covers every tie
    /// between two single-note chords and every tie between two chords
    /// of the same shape. `nil` partner means the neighbouring chord is
    /// unknown (the encoder has no look-ahead past the next measure),
    /// which falls back to the pre-`<notes>` behaviour.
    private func notesDelta(forPitch pitch: Int, partner: ChordNotes?) -> Int {
        guard let partner, !partner.isEmpty else { return 0 }
        return MSCXLocationNoteIndex.index(ofPitch: pitch, in: partner)
            - MSCXLocationNoteIndex.index(ofPitch: pitch, in: notes)
    }

    /// Encode as a `<Rest>` (notes-empty representation). Traps via
    /// `appendDurationXML`'s precondition if `duration == .measure`;
    /// callers that may carry `.measure` rests must use the
    /// `encodeAsRest(options:in:)` overload that supplies the
    /// effective measure duration.
    func encodeAsRest(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Rest", children: children)
    }

    /// Encode as a `<Rest>` (notes-empty representation), resolving
    /// `.measure` against the supplied effective measure duration.
    /// Non-`.measure` durations behave identically to the
    /// single-argument overload.
    func encodeAsRest(
        options: MSCXEncoderOptions = .init(),
        in measureDuration: Fraction,
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children, in: measureDuration)
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Rest", children: children)
    }
}
