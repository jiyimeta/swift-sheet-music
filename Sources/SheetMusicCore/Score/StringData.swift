import SheetMusicFoundation

/// The fretted-instrument tuning stored by MuseScore under `<Instrument>`.
/// C++: `mu::engraving::StringData` (`dom/stringdata.h`).
///
/// This type is tuning data only; nothing in this library yet converts a pitch
/// to a string/fret pair or validates `Note.string` / `Note.fret` against it.
/// `frets` is kept exactly as written and is not normalized to 24 the way
/// `StringData::configBanjo5thString()` does for a five-string banjo, because
/// this model's job is to give back the file it read.
///
/// The same reasoning makes an EMPTY tuning survive where MuseScore drops it.
/// `TWrite` omits the element entirely when `StringData::isNull()` — no frets
/// and no strings (`dom/stringdata.cpp:74-77`, `rw/write/twrite.cpp:2025`) — so
/// MuseScore loads `<StringData/>` and saves nothing. Here a present-but-empty
/// element decodes to `StringData()` and is written back as
/// `<StringData><frets>0</frets></StringData>`. MuseScore re-reads that as the
/// same null tuning, and mirroring the omission instead would make the
/// preservation gate report `Instrument/StringData` as a real loss.
///
/// `nil` on `Instrument.stringData` — no element at all — is the case that
/// writes nothing, and is what every non-TAB instrument has.
public struct StringData: Sendable, Equatable {
    public var frets: Int
    public var strings: [InstrumentString]
    public var preservedMarkup: [PreservedXML]

    public var stringCount: Int {
        strings.count
    }

    public init(
        frets: Int = 0,
        strings: [InstrumentString] = [],
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.frets = frets
        self.strings = strings
        self.preservedMarkup = preservedMarkup
    }
}

/// One string in a fretted instrument's tuning.
/// C++: `mu::engraving::instrString` (`dom/stringdata.h`).
///
/// Upstream's `startFret` is absent because MuseScore derives it at read time
/// and never serializes it.
public struct InstrumentString: Sendable, Equatable {
    public var pitch: Int
    public var isOpen: Bool
    public var useFlat: Bool

    public init(pitch: Int, isOpen: Bool = false, useFlat: Bool = false) {
        self.pitch = pitch
        self.isOpen = isOpen
        self.useFlat = useFlat
    }
}
