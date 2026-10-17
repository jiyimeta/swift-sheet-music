import SheetMusicXMLTools

/// The program that wrote the MusicXML, as MuseScore recognises it from `<identification><encoding><software>`
/// (`MusicXmlParserPass1::setExporterSoftware`, `P1:411-426`). A few readings bend for it: Finale's dynamic letters,
/// Sibelius's metronome words and its early ottava ends.
enum MusicXMLExporterSoftware: Equatable, Sendable {
    case other
    case sibelius
    case dolet6
    case dolet8
    case dorico
    case finale
    case noteflight

    /// The exporter a `<software>` text names, read lower-cased (`P1:411-426`, `1531`); `.other` when it names none
    /// of them, which leaves an earlier recognised one standing (`setExporterSoftware` sets nothing then).
    static func detect(softwareText: String) -> MusicXMLExporterSoftware {
        let text = softwareText.lowercased()
        if text.hasSubstring("sibelius") {
            if text.hasSubstring("dolet 6") { return .dolet6 }
            if text.hasSubstring("dolet 8") { return .dolet8 }
            return .sibelius
        }
        if text.hasSubstring("dorico") { return .dorico }
        if text.hasSubstring("finale") { return .finale }
        if text.hasSubstring("noteflight") { return .noteflight }
        return .other
    }

    /// The exporter the score's `<identification><encoding><software>` elements name: the last one recognised, as
    /// pass 1 reads each in turn (`P1:1525-1532`).
    static func detect(root: XMLTreeNode) -> MusicXMLExporterSoftware {
        var software = MusicXMLExporterSoftware.other
        for identification in root.all("identification") {
            for encoding in identification.all("encoding") {
                for node in encoding.all("software") {
                    let detected = detect(softwareText: node.text)
                    if detected != .other { software = detected }
                }
            }
        }
        return software
    }

    /// Sibelius, or Dolet writing for Sibelius (`sibOrDolet`, `P1:1215-1223`).
    var isSibeliusOrDolet: Bool {
        switch self {
        case .sibelius, .dolet6, .dolet8: true
        case .other, .dorico, .finale, .noteflight: false
        }
    }
}
