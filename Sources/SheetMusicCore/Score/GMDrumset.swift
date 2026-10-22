import SheetMusicFoundation

/// One drum's engraving identity: which line it sits on, what notehead it wears, and which voice — and so which
/// stem direction — it belongs to. MuseScore's `<Drum>` element, one to one.
///
/// `stem` is MuseScore's own encoding: `1` = up, `2` = down. It is stored rather than derived from `voiceIndex`
/// because it is what the file says, and a chart is free to disagree with the convention.
public struct DrumsetEntry: Sendable, Equatable {
    public var name: String
    public var head: String
    public var line: Int
    public var voiceIndex: Int
    public var stem: Int
    /// MuseScore's `<shortcut>` — the key that selects this drum in its own note-input palette. Carried so a
    /// decoded kit re-encodes to the bytes it came from; nothing in this package reads it.
    public var shortcut: String?
    /// The drum's own glyphs when `head` is MuseScore's custom group (`"custom"`): the `<noteheads>` a kit spells
    /// such a drum with, and what a note of it with `<head>custom</head>` draws. `nil` for every other head.
    public var noteheads: DrumsetNoteheads?
    /// `<Drum>` children this model does not represent — MuseScore 4.5+'s `<variants>` and its percussion panel's
    /// `<panelRow>` / `<panelColumn>` — kept so that read → write does not delete them.
    public var preservedMarkup: [PreservedXML]

    public init(
        name: String, head: String, line: Int, voiceIndex: Int, stem: Int, shortcut: String? = nil,
        noteheads: DrumsetNoteheads? = nil, preservedMarkup: [PreservedXML] = [],
    ) {
        self.name = name
        self.head = head
        self.line = line
        self.voiceIndex = voiceIndex
        self.stem = stem
        self.shortcut = shortcut
        self.noteheads = noteheads
        self.preservedMarkup = preservedMarkup
    }
}

/// A drum's own noteheads, one SMuFL glyph name per duration — MuseScore's custom notehead group
/// (`DrumInstrument::noteheads`), which a kit holds as `<noteheads>` and its notes name as `<head>custom</head>`.
/// The stock Drumset's China cymbal is one, drawn as `noteheadHeavyXHat` at every duration. A duration the file does
/// not name keeps MuseScore's default for it.
public struct DrumsetNoteheads: Sendable, Equatable {
    public var whole: String
    public var half: String
    public var quarter: String
    public var breve: String

    public init(
        whole: String = "noteheadWhole", half: String = "noteheadHalf", quarter: String = "noteheadBlack",
        breve: String = "noteheadDoubleWhole",
    ) {
        self.whole = whole
        self.half = half
        self.quarter = quarter
        self.breve = breve
    }
}

/// The General MIDI drum kit as MuseScore Studio's stock drumset engraves it — the defaults an authored kit gets
/// and the gap-filler for a decoded one.
///
/// This table used to be four separate halves: `GMPercussion.drumLineMap` held the lines publicly, while
/// `MSCXEncoder+Instrument` held the names, heads and voices in three private functions, because MuseScore Studio
/// silently ignores a `<Drum>` entry lacking `<head>` / `<voice>` / `<stem>` and collapses every drum onto one
/// line — so the encoder needed them and nothing else did. Drum note entry needs the same facts on the way IN, so
/// they live in one place now.
///
/// Every value is MuseScore Studio's own, taken from `share/instruments/instruments.xml`'s
/// `<Instrument id="drumset">` — the block a Drumset part is actually built from, so a score authored here and one
/// authored there engrave the same drum on the same line. The four pitches that block omits (39 hand clap,
/// 58 vibraslap, 60 / 61 bongos) come from `smDrumset` in `src/engraving/dom/drumset.cpp`, MuseScore's fallback.
/// China cymbal is the one entry that cannot be copied literally: `instruments.xml` spells it as a normal head
/// plus a per-duration `<noteheads>` override to `noteheadHeavyXHat`, which a single `head` cannot say, so it is
/// written as the `heavy-cross-hat` group — the same four glyphs.
///
/// It did not always agree. Until 2.3.1 the lines were a table of unknown origin that matched MuseScore on only
/// five of twenty-seven pitches — the kick a line high, every tom two lines off — and open hi-hat wore the closed
/// hi-hat's head. Scores written before then keep their own `<Drum>` lines, which is why nothing migrates: the
/// notes are already engraved where the file says.
///
/// This is NOT "the" drum table. `PDFImporter.defaultDrumLineMap` is deliberately a different one — MuseScore 3's
/// stock drumset, whose lines are what actually positioned the noteheads in the PDF being read — and
/// `MidiImporter.gmDrumHeads` deliberately differs on a handful of pitches, because it is choosing heads for a
/// track that never said what it wanted. Both are left alone.
public enum GMDrumset {
    public static let entries: [Int: DrumsetEntry] = [
        35: DrumsetEntry(name: "Bass Drum 2", head: "normal", line: 8, voiceIndex: 1, stem: 2),
        36: DrumsetEntry(name: "Bass Drum 1", head: "normal", line: 7, voiceIndex: 1, stem: 2),
        37: DrumsetEntry(name: "Side Stick", head: "slashed1", line: 3, voiceIndex: 0, stem: 1),
        38: DrumsetEntry(name: "Acoustic Snare", head: "normal", line: 3, voiceIndex: 0, stem: 1),
        39: DrumsetEntry(name: "Hand Clap", head: "plus", line: -2, voiceIndex: 0, stem: 1),
        40: DrumsetEntry(name: "Electric Snare", head: "slash", line: 3, voiceIndex: 0, stem: 1),
        41: DrumsetEntry(name: "Low Floor Tom", head: "normal", line: 6, voiceIndex: 0, stem: 1),
        42: DrumsetEntry(name: "Closed Hi-Hat", head: "cross", line: -1, voiceIndex: 0, stem: 1),
        43: DrumsetEntry(name: "High Floor Tom", head: "normal", line: 5, voiceIndex: 0, stem: 1),
        44: DrumsetEntry(name: "Pedal Hi-Hat", head: "cross", line: 9, voiceIndex: 1, stem: 2),
        45: DrumsetEntry(name: "Low Tom", head: "normal", line: 4, voiceIndex: 0, stem: 1),
        46: DrumsetEntry(name: "Open Hi-Hat", head: "xcircle", line: -1, voiceIndex: 0, stem: 1),
        47: DrumsetEntry(name: "Low-Mid Tom", head: "normal", line: 2, voiceIndex: 0, stem: 1),
        48: DrumsetEntry(name: "Hi-Mid Tom", head: "normal", line: 1, voiceIndex: 0, stem: 1),
        49: DrumsetEntry(name: "Crash Cymbal 1", head: "cross", line: -2, voiceIndex: 0, stem: 1),
        50: DrumsetEntry(name: "High Tom", head: "normal", line: 0, voiceIndex: 0, stem: 1),
        51: DrumsetEntry(name: "Ride Cymbal 1", head: "cross", line: 0, voiceIndex: 0, stem: 1),
        52: DrumsetEntry(name: "China Cymbal", head: "heavy-cross-hat", line: -3, voiceIndex: 0, stem: 1),
        53: DrumsetEntry(name: "Ride Bell", head: "diamond", line: 0, voiceIndex: 0, stem: 1),
        54: DrumsetEntry(name: "Tambourine", head: "diamond", line: 1, voiceIndex: 0, stem: 1),
        55: DrumsetEntry(name: "Splash Cymbal", head: "cross", line: -4, voiceIndex: 0, stem: 1),
        56: DrumsetEntry(name: "Cowbell", head: "triangle-down", line: 1, voiceIndex: 0, stem: 1),
        57: DrumsetEntry(name: "Crash Cymbal 2", head: "cross", line: -3, voiceIndex: 0, stem: 1),
        58: DrumsetEntry(name: "Vibraslap", head: "ti", line: 0, voiceIndex: 0, stem: 1),
        59: DrumsetEntry(name: "Ride Cymbal 2", head: "cross", line: 2, voiceIndex: 0, stem: 1),
        60: DrumsetEntry(name: "Hi Bongo", head: "normal", line: -1, voiceIndex: 0, stem: 1),
        61: DrumsetEntry(name: "Low Bongo", head: "normal", line: 0, voiceIndex: 0, stem: 1),
    ]

    /// The entry for `pitch`, placed on `line`. A pitch the GM table does not name still gets a complete,
    /// writable entry: MuseScore drops a `<Drum>` that lacks `<name>` / `<head>` / `<voice>` / `<stem>`
    /// altogether, so an incomplete answer here is the same as no answer at all.
    public static func entry(forPitch pitch: Int, line: Int) -> DrumsetEntry {
        guard var entry = entries[pitch] else {
            return DrumsetEntry(name: "Drum \(pitch)", head: "normal", line: line, voiceIndex: 0, stem: 1)
        }
        entry.line = line
        return entry
    }
}
