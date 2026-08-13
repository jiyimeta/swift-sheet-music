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
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        duration.appendDurationXML(to: &children)
        children.append(XMLTreeNode(name: graceType.mscxTag))
        for note in notes {
            children.append(note.encode(options: options))
        }
        return XMLTreeNode(name: "Chord", children: children)
    }
}
