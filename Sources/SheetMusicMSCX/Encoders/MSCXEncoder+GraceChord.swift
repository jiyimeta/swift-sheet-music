import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension GraceChord {
    /// Build the `<Chord>` element for a grace note.
    ///
    /// In the mscx voice stream a grace note is its own `<Chord>`
    /// *sibling* of the chord it decorates — not a child — distinguished
    /// from an ordinary chord only by an empty grace-type tag
    /// (`<acciaccatura/>`, `<appoggiatura/>`, `<grace4/>`, `<grace16/>`,
    /// `<grace32/>`, `<grace8after/>`, `<grace16after/>`,
    /// `<grace32after/>`; see `GraceType.mscxTag`). `Voice.emitElement`
    /// places every grace — before *and* after type — ahead of the
    /// parent chord's own `<Chord>` node, in the single file order
    /// `Chord.mscxFileOrderedGraces` defines.
    ///
    /// `duration` is written straight through, unlike an ordinary
    /// chord's duration: grace notes don't consume tuplet time, so the
    /// decoder deliberately never scales them by the enclosing tuplet
    /// ratio (`MSCXDecoder+Voice.swift`) — running this value through
    /// `unscaledDuration` on the way out would un-scale a value that was
    /// never scaled in, corrupting it. Element order otherwise mirrors
    /// an ordinary chord: `<dots>`/`<durationType>`
    /// (`NoteDuration.appendDurationXML`), then the grace tag, then one
    /// `<Note>` per note, reusing the same note encoder an ordinary
    /// chord's notes go through.
    ///
    /// ## Which chord a grace's own tie points at
    ///
    /// A grace chord shares its parent chord's tick — MuseScore's
    /// writer never advances the cursor for a grace item
    /// (`TWrite::write(const ChordRest*, …)`,
    /// `rw/write/twrite.cpp:1127-1133`, guards `ctx.incCurTick` with
    /// `!item->isGrace()`) because `EngravingItem::tick()`
    /// (`dom/engravingitem.cpp:584-596`) resolves through the enclosing
    /// `Segment`, which a grace shares with the chord it decorates. So
    /// a tie between a grace and a note of its **own parent chord** is a
    /// zero-delta, same-measure tie: `TieLocation.graceZeroDelta`. See
    /// that constant's doc comment for why an *absent* `<location>` is
    /// not merely imprecise but silently drops the tie on reload.
    ///
    /// The other direction of each tie leaves the parent, and there the
    /// zero delta would name the wrong chord. Sounding order decides
    /// which case applies, and it is fully determined by the grace type:
    ///
    /// | | `tieBack` (`<prev>`) | `tieForward` (`<next>`) |
    /// | --- | --- | --- |
    /// | before-grace | previous main chord — `parentBackwardTieLocation` | own parent chord — zero delta |
    /// | after-grace | own parent chord — zero delta | next main chord — `parentForwardTieLocation` |
    ///
    /// A before-grace sounds *ahead of* its parent, so nothing of the
    /// parent can tie into it and its `tieBack` must come from the
    /// chord before; an after-grace sounds *after* its parent, so the
    /// mirror holds. Because the grace shares the parent's tick, "the
    /// chord before/after the parent" is exactly the delta the parent's
    /// own ordinary tie location carries — hence the two parameters,
    /// which `Voice.emitElement` fills from `Voice.backwardTieDelta` /
    /// `forwardTieDelta` (the unguarded forms: the parent chord itself
    /// need not carry any tie).
    ///
    /// When the needed parent location is `nil` — no previous chord to
    /// point at — no `<location>` is written at all. That drops the tie
    /// on reload, but so would a confidently wrong one, and a wrong
    /// location can additionally mis-connect to some *other* note that
    /// happens to sit there.
    ///
    /// Not covered: a tie between a grace of one chord and a grace of
    /// the neighbouring chord (a Nachschlag tied into the next chord's
    /// Vorschlag). That needs `<grace>` naming the partner's ordinal
    /// within the *other* chord's run, which neither side has visibility
    /// into here; such a tie is written with the plain neighbour-chord
    /// location and is dropped on reload.
    ///
    /// `parentChord` supplies the note list the `<notes>` delta is
    /// measured against for the zero-delta cases (`TieEndpoint`). It is
    /// optional so a grace can still be encoded standalone; without it
    /// the delta is `0`, which is correct exactly when both tied notes
    /// are alone in their chords.
    /// `listIndex` is this grace's position within the parent's own
    /// `graceNotesBefore` / `graceNotesAfter` list. Guitar bends chain from
    /// one grace of a run to the next, so a grace has to know where in its run
    /// it sits to name its neighbour — see `guitarBendForwardEndpoint`. Ties
    /// never need it (the tie encoder resolves grace partners from the parent
    /// side instead), so it defaults to `0`, the value that makes a lone grace
    /// behave identically.
    func encode(
        parentChord: Chord? = nil,
        parentForwardTieLocation: TieLocation? = nil,
        parentBackwardTieLocation: TieLocation? = nil,
        listIndex: Int = 0,
        options: MSCXEncoderOptions = .init(),
    ) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        children.append(XMLTreeNode(name: graceType.mscxTag))
        for note in notes {
            children.append(note.encode(
                tieForwardEndpoint: note.tieForward == nil ? nil : endpoint(
                    forNote: note,
                    towardsParent: !graceType.isAfter,
                    awayFromParent: parentForwardTieLocation,
                    parentChord: parentChord,
                ),
                tieBackEndpoint: note.tieBack == nil ? nil : endpoint(
                    forNote: note,
                    towardsParent: graceType.isAfter,
                    awayFromParent: parentBackwardTieLocation,
                    parentChord: parentChord,
                ),
                guitarBendForwardEndpoint: guitarBendForwardEndpoint(
                    for: note,
                    parentChord: parentChord,
                    listIndex: listIndex,
                    awayFromParent: parentForwardTieLocation,
                ),
                guitarBendBackEndpoint: guitarBendBackEndpoint(
                    for: note,
                    parentChord: parentChord,
                    listIndex: listIndex,
                    awayFromParent: parentBackwardTieLocation,
                ),
                options: options,
            ))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "Chord", children: children)
    }

    /// Resolve one side of one grace note's tie to its `<location>`
    /// payload, per the table in `encode`'s doc comment.
    private func endpoint(
        forNote note: Note,
        towardsParent: Bool,
        awayFromParent: TieLocation?,
        parentChord: Chord?,
    ) -> TieEndpoint? {
        guard towardsParent else {
            return awayFromParent.map { TieEndpoint($0) }
        }
        let parentNoteIndex = parentChord.map {
            MSCXLocationNoteIndex.index(ofPitch: note.pitch, in: $0.notes)
        } ?? 0
        return TieEndpoint(
            .graceZeroDelta,
            notesDelta: parentNoteIndex
                - MSCXLocationNoteIndex.index(ofPitch: note.pitch, in: notes),
        )
    }
}
