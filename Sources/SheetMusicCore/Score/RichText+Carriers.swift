import SheetMusicFoundation

// The formatted text each carrier's preserved `<text>` markup describes, while it still describes the carrier's `text`
// (`PreservedTextMarkup.richText(ifCurrentFor:)`). Computed, never stored: an edit leaves the carrier plain text,
// exactly as the encoder then saves it.

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
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Fingering {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Sticking {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension Capo {
    public var richText: RichText? {
        preservedTextMarkup?.richText(ifCurrentFor: text)
    }
}

extension StringTunings {
    public var richText: RichText? {
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
    public var richText: RichText? {
        text.flatMap { preservedTextMarkup?.richText(ifCurrentFor: $0) }
    }
}

extension Spanner {
    /// `beginText` read as what it is: MuseScore xml text held as a string — it writes a `TextLineBase`'s
    /// `<beginText>` escaped (`XmlWriter::tagProperty`), so `<sym>` and `<b>` arrive here as characters.
    public var beginRichText: RichText? {
        beginText.map { RichText(xmlText: $0) }
    }
}
