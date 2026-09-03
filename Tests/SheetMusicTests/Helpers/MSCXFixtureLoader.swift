import Foundation
import Testing

/// Loads `.mscx` / `.mscz` test fixtures from
/// `Tests/SheetMusicTests/Resources/`.
///
/// The on-disk files are GPL-3.0 copies of MuseScore's own test
/// fixtures (see `Tests/SheetMusicTests/Resources/LICENSE`). They live
/// only in the test target and are not shipped in any library product.
enum MSCXFixtureLoader {
    /// Every committed `.mscx` fixture, recursively, sorted by path.
    ///
    /// Sorted rather than in enumeration order because the preservation
    /// gate reports one issue per lost element pair, and an unstable
    /// order would reshuffle a failing run's output between runs.
    static func allMSCXURLs() -> [URL] {
        guard let root = TestResources.resourceURL,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: nil,
              )
        else { return [] }

        let found = (enumerator.allObjects as? [URL] ?? []).filter {
            $0.pathExtension.lowercased() == "mscx"
        }
        return found.sorted { $0.path < $1.path }
    }

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
