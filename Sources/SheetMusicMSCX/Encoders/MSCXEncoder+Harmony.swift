import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Harmony {
    /// Build a `<Harmony>` element. Mirrors `Harmony.decode(_:)`:
    /// `<name>`, `<harmonyType>` (0/1/2), `<root>` / `<bass>` (TPC,
    /// omitted when nil), `<rootCase>` / `<bassCase>` (omitted when
    /// `.auto`), self-closing `<leftParen/>` / `<rightParen/>` flags,
    /// `<play>` (only when false), `<offset>`, the `TextProperties` block, and
    /// a trailing `<color>` that cannot be reset by a later `<style>`.
    ///
    /// **The chord-symbol content moves with the target version.**
    /// MuseScore 4.6 wrapped `<name>` / `<root>` / `<bass>` in a
    /// `<harmonyInfo>` element and renamed `<base>` → `<bass>` /
    /// `<baseCase>` → `<bassCase>` (`rw/read460/tread.cpp:2957-2986`
    /// vs `rw/read410/tread.cpp:2991`). We declare `version="4.60"`
    /// for `.v4`, so MuseScore reads those files with read460, which
    /// treats the flat children as unknown and drops them — leaving a
    /// `Harmony` with no `HarmonyInfo`, which `TWrite::write` then
    /// skips entirely. Writing the flat form under a 4.60 header
    /// therefore loses EVERY chord symbol on the round trip
    /// (measured against MuseScore 4.7.4). `.v3` keeps the flat form,
    /// which is what read410 / read400 / read114 expect.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        let usesHarmonyInfo = options.targetVersion == .v4
        var children = chordContent(usesHarmonyInfo: usesHarmonyInfo)
        if rootCase != .auto {
            children.append(XMLTreeNode(
                name: "rootCase", text: encodeNoteCase(rootCase),
            ))
        }
        if bassCase != .auto {
            children.append(XMLTreeNode(
                name: usesHarmonyInfo ? "bassCase" : "baseCase",
                text: encodeNoteCase(bassCase),
            ))
        }
        if leftParen {
            children.append(XMLTreeNode(name: "leftParen"))
        }
        if rightParen {
            children.append(XMLTreeNode(name: "rightParen"))
        }
        if !play {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        properties.appendXML(to: &children)
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        children += elementProperties.mscxTrailingChildren()
        return XMLTreeNode(name: "Harmony", children: children)
    }

    /// The chord-symbol content — `<name>`, `<root>`, the slash bass —
    /// plus `<harmonyType>`, laid out for the target reader.
    /// `<harmonyType>` is a direct child of `<Harmony>` either way;
    /// only the name / root / bass trio moves into `<harmonyInfo>`.
    private func chordContent(usesHarmonyInfo: Bool) -> [XMLTreeNode] {
        var content: [XMLTreeNode] = [
            XMLTreeNode(name: "name", text: name),
        ]
        if let rootTpc {
            content.append(XMLTreeNode(name: "root", text: String(rootTpc)))
        }
        if let bassTpc {
            content.append(XMLTreeNode(
                name: usesHarmonyInfo ? "bass" : "base",
                text: String(bassTpc),
            ))
        }
        let type = XMLTreeNode(
            name: "harmonyType", text: encodeHarmonyType(harmonyType),
        )
        if usesHarmonyInfo {
            return [type, XMLTreeNode(name: "harmonyInfo", children: content)]
        }
        return [content[0], type] + content.dropFirst()
    }
}

private func encodeHarmonyType(_ type: HarmonyType) -> String {
    switch type {
    case .standard: "0"
    case .roman: "1"
    case .nashville: "2"
    }
}

private func encodeNoteCase(_ noteCase: NoteCase) -> String {
    switch noteCase {
    case .auto: "0"
    case .upper: "1"
    case .lower: "2"
    case .capitalize: "3"
    }
}
