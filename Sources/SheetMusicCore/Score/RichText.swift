import SheetMusicFoundation

/// Formatted text as MuseScore lays a text element out: lines of runs, each a string or a SMuFL symbol, carrying the
/// character format in force where it appears.
///
/// Built by MuseScore's own format state machine — `TextBase::createBlocks` and `prepareFormat`
/// (`engraving/dom/textbase.cpp:1659-1818`) — from either shape MuseScore stores formatted text in:
///
/// - `init(markup:)` / `init(content:)`: the element tree of a `<text>` child, which `TRead::readTextProperties` reads
///   with `readXml()` (`rw/read460/tread.cpp:4534-4537`), so its tags are XML elements.
/// - `init(xmlText:)`: the same markup held as a string — a `TextLineBase`'s `<beginText>`, `<continueText>` and
///   `<endText>`, which MuseScore writes as an escaped string property (`XmlWriter::tagProperty`,
///   `rw/xmlwriter.cpp:100-137`), so its tags reach the parser as characters.
///
/// Format tags are state changes, not wrappers: `<b>` sets bold and `</b>` clears it, `<font size="12"/>` sets the size
/// for everything after it. `<br/>` and a literal line feed start a line; `<sym>name</sym>` appends a symbol run. Any
/// other tag is transparent.
///
/// Computed on demand from preserved markup (each carrier's `richText`) and deliberately not `Hashable`: it never sits
/// in a hashed model value, and synthesizing `Hashable` over recursive markup cost the WebAssembly probe 1,146 brotli
/// bytes once already (`PreservedTextMarkup`).
public struct RichText: Sendable, Equatable {
    /// One entry per line, never empty: text without characters is one empty line.
    public var lines: [[RichTextRun]]

    public init(lines: [[RichTextRun]]) {
        self.lines = lines.isEmpty ? [[]] : lines
    }

    /// The plain projection a text carrier stores as `text`: each line's characters in source order, the lines joined
    /// by `"\n"`. A symbol contributes nothing — it is a glyph, and its SMuFL name is not text. Not trimmed, so it
    /// always has exactly `lines.count` lines.
    public var plainText: String {
        lines.map { line in
            line.reduce(into: "") { result, run in
                if case let .text(text, _) = run { result += text }
            }
        }
        .joined(separator: "\n")
    }
}

/// One run of a `RichText` line.
public enum RichTextRun: Sendable, Equatable {
    case text(String, RichTextFormat)
    /// A SMuFL glyph name as MuseScore writes it inside `<sym>` — `dynamicPiano`, `metNoteQuarterUp`, `coda`.
    case symbol(name: String, RichTextFormat)
}

/// The character format MuseScore's state machine carries (`CharFormat`). A field is `nil` until the markup sets it,
/// meaning "the element's own style": `<b>` makes `bold` `true` and `</b>` makes it `false`, so text after a `</b>` is
/// regular even in a bold style (a tempo or rehearsal mark), exactly as `prepareFormat` makes it.
public struct RichTextFormat: Sendable, Equatable {
    /// `VerticalAlignment` (`engraving/dom/textbase.h:57`), spelled MuseScore's way — `subscript` is a Swift keyword.
    public enum VerticalAlign: Sendable, Equatable {
        case normal
        case superScript
        case subScript
    }

    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    /// `<font face="…"/>`; `nil` = the element's face.
    public var face: String?
    /// `<font size="…"/>` in points at MuseScore's reference spatium; `nil` = the element's size.
    public var size: Double?
    public var verticalAlign: VerticalAlign

    public init(
        bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strike: Bool? = nil,
        face: String? = nil, size: Double? = nil, verticalAlign: VerticalAlign = .normal,
    ) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.face = face
        self.size = size
        self.verticalAlign = verticalAlign
    }
}

extension RichText {
    /// The `<text>` markup a decoder preserved, interpreted.
    public init(markup: PreservedTextMarkup) {
        self.init(content: markup.content)
    }

    /// A `<text>` element's content, interpreted in source order.
    public init(content: [PreservedTextMarkup.ContentItem]) {
        var builder = RichTextBuilder()
        builder.walk(content)
        self = builder.richText
    }

    /// MuseScore xml text held as a string (`<beginText>` and its siblings), interpreted as `createBlocks` reads it —
    /// except that a `<` no `>` closes and an `&` that starts no known entity stay literal, so a label typed as text
    /// ("1 & 2") draws as typed.
    public init(xmlText: String) {
        var builder = RichTextBuilder()
        builder.parse(xmlText)
        self = builder.richText
    }
}

extension PreservedTextMarkup {
    /// This markup as `RichText` while it still describes `text` — the encoder's own condition for writing it back
    /// (`derivedText == text`, `MSCXEncoder+TextMarkup.swift`). `nil` once the text has been edited: the element is
    /// then plain text, exactly as it is then saved.
    public func richText(ifCurrentFor text: String) -> RichText? {
        derivedText == text ? RichText(markup: self) : nil
    }
}
