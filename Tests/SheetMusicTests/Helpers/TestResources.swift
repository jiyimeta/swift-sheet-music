import Foundation

/// Resolves test fixtures through SwiftPM resources on native platforms and
/// through the PackageToJS preopened test bundle under WASI.
enum TestResources {
    static var resourceURL: URL? {
        #if SHEET_MUSIC_HAS_PREOPENED_TEST_RESOURCES
            resourceRootURL
        #else
            Bundle.module.resourceURL
        #endif
    }

    static func url(
        forResource name: String?,
        withExtension ext: String?,
        subdirectory: String? = nil,
    ) -> URL? {
        #if SHEET_MUSIC_HAS_PREOPENED_TEST_RESOURCES
            guard let name else { return nil }
            var url = resourceRootURL
            if let subdirectory {
                url.appendPathComponent(subdirectory, isDirectory: true)
            }
            url.appendPathComponent(name)
            if let ext {
                url.appendPathExtension(ext)
            }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
            return Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: subdirectory,
            )
        #endif
    }

    #if SHEET_MUSIC_HAS_PREOPENED_TEST_RESOURCES
        private static let resourceRootURL = URL(
            fileURLWithPath: #filePath,
        )
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            ".build/wasm32-unknown-wasip1/debug/"
                + "swift-sheet-music_SheetMusicTests.resources",
            isDirectory: true,
        )
    #endif
}
