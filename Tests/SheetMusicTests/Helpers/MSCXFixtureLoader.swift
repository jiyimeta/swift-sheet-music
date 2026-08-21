import Foundation
import Testing

/// Loads `.mscx` / `.mscz` test fixtures from
/// `Tests/SheetMusicTests/Resources/`.
///
/// The on-disk files are GPL-3.0 copies of MuseScore's own test
/// fixtures (see `Tests/SheetMusicTests/Resources/LICENSE`). They live
/// only in the test target and are not shipped in any library product.
enum MSCXFixtureLoader {
    static func mscxData(_ name: String) throws -> Data {
        let url = try #require(
            TestResources.url(forResource: name, withExtension: "mscx"),
            "fixture mscx not bundled: \(name).mscx",
        )
        return try Data(contentsOf: url)
    }

    static func msczData(_ name: String) throws -> Data {
        let url = try #require(
            TestResources.url(forResource: name, withExtension: "mscz"),
            "fixture mscz not bundled: \(name).mscz",
        )
        return try Data(contentsOf: url)
    }
}
