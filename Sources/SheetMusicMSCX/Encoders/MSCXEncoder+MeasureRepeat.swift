import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension MeasureRepeat {
    /// Build the measure-repeat element. The wire-form name and
    /// header child differ between targets: v4 emits
    /// `<MeasureRepeat><subtype>N</subtype>…</MeasureRepeat>` matching
    /// MuseScore 4's serialization, while v3 emits the legacy
    /// `<RepeatMeasure><linkedMain/>…</RepeatMeasure>` form that
    /// MuseScore 3.6.2's reader recognises. Native MS3 treats the v4
    /// element name as an unknown tag and skips the body, leaving the
    /// bar empty (`got 0/1`) and surfacing an "incomplete measure"
    /// diagnostic on file open. The duration is preserved in
    /// MuseScore's canonical measure-repeat form
    /// (`<durationType>measure</durationType>` + `<duration>N/D
    /// </duration>`) on both branches.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        let elementName: String
        var children: [XMLTreeNode] = []
        switch options.targetVersion {
        case .v2, .v3:
            elementName = "RepeatMeasure"
            children.append(XMLTreeNode(name: "linkedMain"))
        case .v4:
            elementName = "MeasureRepeat"
            children.append(XMLTreeNode(
                name: "subtype", text: String(numMeasures),
            ))
        }
        if case let .fraction(f) = duration {
            children.append(XMLTreeNode(name: "durationType", text: "measure"))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)",
            ))
        } else {
            duration.appendDurationXML(to: &children)
        }
        return XMLTreeNode(name: elementName, children: children)
    }
}
