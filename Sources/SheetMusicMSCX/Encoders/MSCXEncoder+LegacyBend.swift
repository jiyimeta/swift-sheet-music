import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension LegacyBend {
    /// Build the `<Bend>` element. Field order mirrors both writers —
    /// points, then the styled properties, then `<play>`, which is written
    /// only when it is false because `writeProperty(Pid::PLAY)` elides the
    /// default. The four styled properties are likewise absent unless the
    /// user overrode them, so an untouched bend writes back as nothing but
    /// its curve.
    /// C++: `TWrite::write(const Bend*, …)` (`rw/write/twrite.cpp:825`),
    /// 3.6.2 `Bend::write` (`libmscore/bend.cpp:285`). The two are
    /// identical, so no target-version branch exists here.
    ///
    /// The point attributes go in as a dictionary, the same way every other
    /// attribute-carrying encoder in this module writes one (see the
    /// `<color r= g= b= a=>` writers): `XMLTreeSerializer` emits attributes
    /// in sorted key order, so the rendered element reads
    /// `<point pitch= time= vibrato=/>` rather than MuseScore's
    /// `time`/`pitch`/`vibrato`. Attribute order carries no meaning in XML
    /// and MuseScore's reader looks each one up by name; byte parity with
    /// Studio's own writer is a stated non-goal of the serializer.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = points.map { point in
            XMLTreeNode(name: "point", attributes: [
                "time": String(point.time),
                "pitch": String(point.pitch),
                "vibrato": String(point.vibrato),
            ])
        }
        if let lineWidth {
            children.append(XMLTreeNode(
                name: "lineWidth", text: formatDouble(lineWidth),
            ))
        }
        if let fontFace {
            children.append(XMLTreeNode(name: "fontFace", text: fontFace))
        }
        if let fontSize {
            children.append(XMLTreeNode(
                name: "fontSize", text: formatDouble(fontSize),
            ))
        }
        if let fontStyle {
            children.append(XMLTreeNode(
                name: "fontStyle", text: String(fontStyle),
            ))
        }
        if !play {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        return XMLTreeNode(name: "Bend", children: children)
    }
}
