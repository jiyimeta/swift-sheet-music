import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicPDFWriter

/// What the writer tests share: the bundled fonts, the metrics table's provider, and one page walked under it.
enum WriterFixtures {
    /// - Parameters:
    ///   - system: the platform UI face's files, as a Windows host hands them over; none by default.
    ///   - fallback: the host's fallback spans for a line; none by default.
    ///   - outlines: the host's outline for a character no font covers; none by default.
    static func fonts(
        system: @escaping @Sendable (FontWeight, Bool) -> ScorePDFFontFile? = { _, _ in nil },
        fallback: @escaping @Sendable (ScorePDFTextLine) -> [ScorePDFFallbackSpan] = { _ in [] },
        outlines: @escaping @Sendable (Unicode.Scalar, ScorePDFTextStyle) -> ScorePDFGlyphOutline? = { _, _ in nil },
    ) throws -> ScorePDFFonts {
        try ScorePDFFonts(
            smufl: BundledFonts.data("Bravura.otf"), roman: BundledFonts.data("Edwin-Roman.otf"),
            bold: BundledFonts.data("Edwin-Bold.otf"), italic: BundledFonts.data("Edwin-Italic.otf"),
            boldItalic: BundledFonts.data("Edwin-BdIta.otf"), system: system, fallback: fallback, outlines: outlines,
        )
    }

    /// The provider a Windows host installs for the faces it bundles: the measured table.
    static func tableProvider() throws -> any FontMetricsProvider {
        try makeFontMetricsTableProvider(table: FontMetricsTable.decode(BundledFonts.data("sheet-music.smft")))
    }

    /// `commands` walked on an A4 page under the table's provider: the content stream, and the resources it used.
    static func walk(
        _ commands: [DrawCommand],
        system: @escaping @Sendable (FontWeight, Bool) -> ScorePDFFontFile? = { _, _ in nil },
        fallback: @escaping @Sendable (ScorePDFTextLine) -> [ScorePDFFallbackSpan] = { _ in [] },
        outlines: @escaping @Sendable (Unicode.Scalar, ScorePDFTextStyle) -> ScorePDFGlyphOutline? = { _, _ in nil },
    ) throws -> (content: String, resources: PDFResources) {
        let resources = try PDFResources(fonts: fonts(system: system, fallback: fallback, outlines: outlines))
        var walker = PDFPageWalker(resources: resources, pageHeightMM: 297)
        try FontMetrics.$scopedProvider.withValue(tableProvider()) {
            walker.walk(commands)
        }
        return (walker.content, resources)
    }

    /// One part of `measures` measures of four quarter notes in 4/4, treble clef.
    static func musicXML(measures: Int, title: String = "Prelude") -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
        <work><work-title>\(title)</work-title></work>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1">

        """
        for measure in 1 ... measures {
            xml += "<measure number=\"\(measure)\">"
            if measure == 1 {
                xml += "<attributes><divisions>1</divisions><key><fifths>0</fifths></key>"
                xml += "<time><beats>4</beats><beat-type>4</beat-type></time>"
                xml += "<clef><sign>G</sign><line>2</line></clef></attributes>"
            }
            for step in ["C", "E", "G", "E"] {
                xml += "<note><pitch><step>\(step)</step><octave>5</octave></pitch>"
                xml += "<duration>1</duration><type>quarter</type></note>"
            }
            xml += "</measure>\n"
        }
        return xml + "</part>\n</score-partwise>\n"
    }

    /// Chords with at least one note, across the score: what sounds.
    static func soundingChords(_ score: Score) -> Int {
        var count = 0
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            if case let .chord(chord) = element, !chord.notes.isEmpty { count += 1 }
                        }
                    }
                }
            }
        }
        return count
    }
}
