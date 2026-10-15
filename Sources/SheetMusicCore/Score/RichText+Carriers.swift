import SheetMusicFoundation

// The formatted text each carrier's preserved `<text>` markup describes, while it still describes the carrier's `text`
// (`PreservedTextMarkup.richText(ifCurrentFor:)`). Computed, never stored: an edit leaves the carrier plain text,
// exactly as the encoder then saves it.
//
// Public on the carriers layout draws from its runs that other modules read; `package` on the annotation carriers
// layout draws (expression, sticking, capo, string tunings, fingering); the glissando label and a line spanner's begin
// text stay internal.

extension StaffText {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Swing {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension InstrumentChange {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension RehearsalMark {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension ExpressionText {
    package var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Fingering {
    package var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Sticking {
    package var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Capo {
    package var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension StringTunings {
    package var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Marker {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Jump {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Lyric {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension FrameText {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Glissando {
    /// `text` is optional; a label whose plain projection is empty (only a `<sym>`) is `""`. A cleared label (`text`
    /// is `nil`) has no rich text: the encoder writes no `<text>` for it.
    var richText: RichText? {
        text.flatMap { preservedTextMarkup?.richText(ifCurrentFor: $0) }
    }
}

extension Spanner {
    /// `beginText` read as what it is: MuseScore xml text held as a string — it writes a `TextLineBase`'s
    /// `<beginText>` escaped (`XmlWriter::tagProperty`), so `<sym>` and `<b>` arrive here as characters.
    var beginRichText: RichText? {
        beginText.map { RichText(xmlText: $0) }
    }
}

extension Tempo {
    /// The authored marking's formatted text while its preserved markup still describes `text`; `nil` otherwise.
    public var richText: RichText? {
        text.flatMap { preservedTextMarkup?.richText(ifCurrentFor: $0) }
    }
}

extension Dynamic {
    /// The dynamic's own formatted text while its preserved markup still describes `text`; `nil` otherwise.
    public var richText: RichText? {
        text.flatMap { preservedTextMarkup?.richText(ifCurrentFor: $0) }
    }
}
