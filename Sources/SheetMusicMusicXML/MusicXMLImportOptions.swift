/// What a MusicXML import may be asked to do. Internal on purpose (`package`): the public entry points use the default.
package struct MusicXMLImportOptions: Sendable, Equatable {
    /// MuseScore's "Infer text type based on content where possible" (`importInferTextType`, default OFF in the app,
    /// `musicxmlconfiguration.cpp:78`; the CLI sets it with `--musicxml-infer-text-type`). It decides whether
    /// "rit." is a gradual tempo change and "Allegro" a tempo text (on) or both are staff texts (off). Default ON here:
    /// the MuseScore Import fixtures run with it on (`musicxml_tests.cpp:136`).
    package var inferTextType: Bool

    package init(inferTextType: Bool = true) {
        self.inferTextType = inferTextType
    }

    package static let `default` = MusicXMLImportOptions()
}
