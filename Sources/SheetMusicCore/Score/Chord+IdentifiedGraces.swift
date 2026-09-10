import SheetMusicFoundation

extension Chord {
    /// Carries existing grace slots without turning transport into a copy.
    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        bracket: ChordBracket? = nil,
        lyrics: [Lyric] = [],
        graceNotesBefore: IdentifiedArray<GraceChord>,
        graceNotesAfter: IdentifiedArray<GraceChord>,
        articulations: [ChordArticulation] = [],
        ornaments: [ChordOrnament] = [],
        tremolo: Tremolo? = nil,
        chordLines: [ChordLine] = [],
        spanners: [Spanner] = [],
        visible: Bool = true,
        stemVisible: Bool = true,
        beamVisible: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.bracket = bracket
        self.lyrics = lyrics
        self.graceNotesBefore = graceNotesBefore
        self.graceNotesAfter = graceNotesAfter
        self.articulations = articulations
        self.ornaments = ornaments
        self.tremolo = tremolo
        self.chordLines = chordLines
        self.spanners = spanners
        self.stemVisible = stemVisible
        self.beamVisible = beamVisible
        self.preservedMarkup = preservedMarkup
        elementProperties = ElementProperties(visible: visible)
    }
}
