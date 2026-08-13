import Foundation
import SheetMusicCore
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
    /// places the "before" types immediately ahead of the parent chord's
    /// own `<Chord>` node and the "after" types (`GraceType.isAfter`)
    /// immediately behind it.
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
    /// A tie on a grace note always uses `TieLocation.graceZeroDelta`:
    /// a grace chord shares its parent chord's tick (MuseScore never
    /// advances the write cursor for a grace item —
    /// `TWrite::write(const ChordRest*, …)`,
    /// `rw/write/twrite.cpp:1126-1130`, guards `ctx.incCurTick` with
    /// `!item->isGrace()` — and `EngravingItem::tick()`,
    /// `dom/engravingitem.cpp:584-596`, resolves to the tick of the
    /// enclosing `Segment`, which a grace chord shares with the main
    /// chord it decorates), so a tied acciaccatura/appoggiatura into
    /// its own main note is a same-tick, same-measure tie. See
    /// `TieLocation.graceZeroDelta`'s doc comment for the full
    /// citation trail, including why an *absent* `<location>` (this
    /// project's previous output) is not merely imprecise but silently
    /// drops the tie when MuseScore Studio reloads the file.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        children.append(XMLTreeNode(name: graceType.mscxTag))
        for note in notes {
            children.append(note.encode(
                tieForwardLocation: note.tieForward != nil ? .graceZeroDelta : nil,
                tieBackLocation: note.tieBack != nil ? .graceZeroDelta : nil,
                options: options,
            ))
        }
        return XMLTreeNode(name: "Chord", children: children)
    }
}
