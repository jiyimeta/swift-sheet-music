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
    ///
    /// `bendNeighbourForward` / `bendNeighbourBackward` are the same two
    /// neighbour-chord deltas *unguarded* by any tie: a guitar bend needs them
    /// on chords that carry no tie at all. `previousChordTrailingBendGrace`
    /// completes the backward one when the previous chord's last after-grace
    /// is what a bend ends from — see `Chord.guitarBendBackEndpoint`.
    ///
    /// `slurEndMarkers` are the `<prev>` sides of chord-anchored spanners
    /// that *end* here; the voice walker computes them when it passes the
    /// begin chord (see `MSCXPendingSlurEnd`).
    func encodeAsChord(
        tieForwardLocation: TieLocation? = nil,
        tieBackLocation: TieLocation? = nil,
        tieForwardPartnerNotes: ChordNotes? = nil,
        tieBackPartnerNotes: ChordNotes? = nil,
        bendNeighbourForward: TieLocation? = nil,
        bendNeighbourBackward: TieLocation? = nil,
        previousChordTrailingBendGrace: Int? = nil,
        slurEndMarkers: [XMLTreeNode] = [],
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
        children += chordAnchoredSpanners(ending: slurEndMarkers, options: options)
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
                guitarBendForwardEndpoint: guitarBendForwardEndpoint(
                    for: note, neighbourChord: bendNeighbourForward,
                ),
                guitarBendBackEndpoint: guitarBendBackEndpoint(
                    for: note,
                    neighbourChord: bendNeighbourBackward,
                    previousChordTrailingBendGrace: previousChordTrailingBendGrace,
                ),
                options: options,
                drumDefaultHead: isPercussionV3 ? "normal" : nil,
                chordLines: chordLines.filter { $0.noteIndex == noteIndex },
            ))
        }
        appendChordTail(to: &children, options: options)
        return XMLTreeNode(name: "Chord", children: children)
    }

    /// Append the modeled arpeggio, element properties, and preserved
    /// markup after the notes, matching MuseScore's Chord child order.
    private func appendChordTail(
        to children: inout [XMLTreeNode],
        options: MSCXEncoderOptions,
    ) {
        if let arpeggio {
            children.append(arpeggio.encode())
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
    }

    /// The chord-anchored `<Spanner>` pair sides that belong on this
    /// chord/rest, in MuseScore's slot: immediately after the duration block,
    /// ahead of everything `TWrite::write(const Chord*, …)` adds. Its
    /// `writeProperties(const ChordRest*, …)` writes `<dots>` /
    /// `<durationType>` / `<duration>` and then, at its tail, the slur
    /// spanner loop (`rw/write/twrite.cpp:1093`, loop at `:1135`);
    /// articulations, `<Stem>` and the `<Note>`s all follow it. Both vendored
    /// fixtures show the pair right behind `<durationType>`.
    ///
    /// One deliberate divergence: MuseScore writes `<Lyrics>` *before* the
    /// spanner loop, where this encoder writes it after `<Stem>` — the
    /// package's own ordering, which predates slur support and which the
    /// existing byte-parity fixtures pin. A chord that carries both lyrics
    /// and a slur therefore differs from Studio's own byte order (both
    /// readers are order-tolerant here).
    ///
    /// End markers precede begin markers: MuseScore walks
    /// `spannerMap().findOverlapping(…)`, whose interval tree is visited in
    /// start-tick order (`thirdparty/intervaltree/IntervalTree.h`,
    /// `visit_overlapping`), and a slur ending on this chord necessarily
    /// starts earlier than one beginning on it.
    private func chordAnchoredSpanners(
        ending endMarkers: [XMLTreeNode],
        options: MSCXEncoderOptions,
    ) -> [XMLTreeNode] {
        endMarkers + slurBeginMarkers(options: options)
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
    ///
    /// A rest carries chord-anchored spanner markers exactly as a chord does:
    /// MuseScore anchors slurs to any `ChordRest` and writes both sides
    /// through the one `TWrite::writeProperties(const ChordRest*, …)`.
    func encodeAsRest(
        slurEndMarkers: [XMLTreeNode] = [],
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        children += chordAnchoredSpanners(ending: slurEndMarkers, options: options)
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Rest", children: children)
    }

    /// Encode as a `<Rest>` (notes-empty representation), resolving
    /// `.measure` against the supplied effective measure duration.
    /// Non-`.measure` durations behave identically to the
    /// single-argument overload.
    func encodeAsRest(
        slurEndMarkers: [XMLTreeNode] = [],
        options: MSCXEncoderOptions = .init(),
        in measureDuration: Fraction,
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children, in: measureDuration)
        children += chordAnchoredSpanners(ending: slurEndMarkers, options: options)
        children.append(contentsOf: elementProperties.mscxChildren())
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Rest", children: children)
    }
}

extension Arpeggio {
    /// Build the modeled `<Arpeggio>` payload. Default-valued optional
    /// properties stay elided, matching MuseScore's writer.
    func encode() -> XMLTreeNode {
        var children = [
            XMLTreeNode(name: "subtype", text: String(subtype)),
        ]
        if userLen1 != 0 {
            children.append(XMLTreeNode(name: "userLen1", text: formatDouble(userLen1)))
        }
        if timeStretch != 1 {
            children.append(XMLTreeNode(name: "timeStretch", text: formatDouble(timeStretch)))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Arpeggio", children: children)
    }
}
