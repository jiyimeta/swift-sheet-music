#if canImport(CryptoKit)
    import CryptoKit
    import Foundation
    @testable import SheetMusicZip
    import Testing

    @Suite("ZipReader interop")
    struct ZipReaderInteropTests {
        /// Captured via `unzip -p midi01.mscz <path> | shasum -a 256`
        /// (system unzip on macOS) — establishes interop baseline against
        /// the canonical ZIP extraction.
        private static let midi01Snapshot: [String: String] = [
            "score.mscx": "b34956c60e2e7ac5e188eea27ed0a3071b8c842a7438b39e162b9a73a5a18dd9",
        ]

        @Test
        func midi01EntriesMatchSnapshot() throws {
            let url = try #require(
                TestResources.url(forResource: "midi01", withExtension: "mscz"),
                "midi01.mscz fixture not found in test bundle",
            )
            let data = try Data(contentsOf: url)
            let reader = try ZipReader(data: data)
            // Skip directory entries.
            let filePaths = reader.entries.values
                .filter { !$0.path.hasSuffix("/") }
                .map(\.path)
                .sorted()
            #expect(Set(filePaths) == Set(Self.midi01Snapshot.keys))
            for path in filePaths {
                let bytes = try reader.read(path: path)
                let hex = SHA256.hash(data: bytes)
                    .map { String(format: "%02x", $0) }.joined()
                #expect(
                    hex == Self.midi01Snapshot[path],
                    "SHA256 mismatch for \(path): got \(hex)",
                )
            }
        }
    }
#endif
