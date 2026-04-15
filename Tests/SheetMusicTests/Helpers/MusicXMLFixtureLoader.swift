import Foundation
import Testing

/// Loads the paired MusicXML input (`<name>.xml`) and the MuseScore
/// reference MSCX (`<name>_ref.mscx`) from `Tests/SheetMusicTests/Resources/musicxml/`.
///
/// The underlying files are **copies of MuseScore's GPL-3.0 test fixtures**
/// (see `Tests/SheetMusicTests/Resources/LICENSE`). They live only in the
/// test target and are not shipped in any library product.
enum MusicXMLFixtureLoader {
    /// MusicXML bytes for the fixture named `name` (without extension).
    static func xml(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "xml"),
            "fixture xml not bundled: \(name).xml"
        )
        return try Data(contentsOf: url)
    }

    /// Reference MSCX bytes for the fixture named `name` (without extension).
    /// The on-disk file is `<name>_ref.mscx`.
    static func referenceMscx(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "\(name)_ref", withExtension: "mscx"),
            "fixture ref mscx not bundled: \(name)_ref.mscx"
        )
        return try Data(contentsOf: url)
    }
}
