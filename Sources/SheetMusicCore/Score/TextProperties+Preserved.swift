import SheetMusicFoundation

extension TextProperties {
    /// The font overrides MuseScore writes among a text element's children (`<face>`, `<size>`, `<bold>`, `<italic>`,
    /// `<underline>`, `<strike>`), read from the children a carrier keeps as `preservedMarkup`. Nothing else in
    /// `preserved` is read. Read as `TextProperties.decode` reads the same tags from an element: an empty face and a
    /// non-numeric size are no opinion, and a style is set only when at least one flag child is present.
    package init(fontChildrenOf preserved: [PreservedXML]) {
        self.init()
        func child(_ name: String) -> String? {
            preserved.first { $0.name == name }?.text
        }
        if let face = child("face"), !face.isEmpty { self.face = face }
        if let raw = child("size"), let size = Double(raw) { self.size = size }
        var style = FontStyleSet()
        var anyFlag = false
        for (name, flag) in [
            ("bold", FontStyleSet.bold), ("italic", .italic), ("underline", .underline), ("strike", .strike),
        ] {
            guard let raw = child(name), let value = Int(raw) else { continue }
            anyFlag = true
            if value != 0 { style.insert(flag) }
        }
        if anyFlag { self.style = style }
    }
}

extension ExpressionText {
    package var fontOverrides: TextProperties {
        TextProperties(fontChildrenOf: preservedMarkup)
    }
}

extension Sticking {
    package var fontOverrides: TextProperties {
        TextProperties(fontChildrenOf: preservedMarkup)
    }
}

extension Capo {
    package var fontOverrides: TextProperties {
        TextProperties(fontChildrenOf: preservedMarkup)
    }
}

extension StringTunings {
    package var fontOverrides: TextProperties {
        TextProperties(fontChildrenOf: preservedMarkup)
    }
}

extension Fingering {
    package var fontOverrides: TextProperties {
        TextProperties(fontChildrenOf: preservedMarkup)
    }
}
