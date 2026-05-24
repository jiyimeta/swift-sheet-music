import Foundation
import Testing

/// Verifies `--include-package` is honoured: when set, only codecs whose
/// Kotlin package exactly matches one of the supplied names are written.
@Test func cliIncludePackageFiltersOutput() throws {
    let fixturesDir = try #require(
        Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures"),
    )
    let sourcesDir = fixturesDir.appendingPathComponent("sources")
    let configPath = fixturesDir.appendingPathComponent("kotlin-codegen.json")

    let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
    let outputDir = caches.appendingPathComponent("emit-kotlin-codecs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }

    let executable = productsURL().appendingPathComponent("emit-kotlin-codecs")

    // PointWire normally lands in io.example.audio.serialization. Filtering
    // by a non-matching package must produce zero files (but a clean exit).
    try runCLI(
        executable: executable, config: configPath, source: sourcesDir, output: outputDir,
        includePackages: ["io.example.other"],
    )
    let pointPath = outputDir
        .appendingPathComponent("io/example/audio/serialization/PointCodec.kt")
    #expect(!FileManager.default.fileExists(atPath: pointPath.path))

    // Same package as PointCodec's actual package → file written.
    try runCLI(
        executable: executable, config: configPath, source: sourcesDir, output: outputDir,
        includePackages: ["io.example.audio.serialization"],
    )
    #expect(FileManager.default.fileExists(atPath: pointPath.path))
}

@Test func cliEmitsCodecsAndIsIdempotent() throws {
    let fixturesDir = try #require(
        Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures"),
    )
    let sourcesDir = fixturesDir.appendingPathComponent("sources")
    let configPath = fixturesDir.appendingPathComponent("kotlin-codegen.json")

    // Use ~/Library/Caches rather than FileManager.default.temporaryDirectory
    // (/var/folders/…) because on macOS 15 the per-process filesystem namespace
    // virtualises writes in /var/folders so a subprocess's writes are invisible
    // to the parent test process.
    let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
    let outputDir = caches.appendingPathComponent("emit-kotlin-codecs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputDir) }

    let executable = productsURL().appendingPathComponent("emit-kotlin-codecs")

    try runCLI(executable: executable, config: configPath, source: sourcesDir, output: outputDir)

    let expected = outputDir
        .appendingPathComponent("io/example/audio/serialization/PointCodec.kt")
    #expect(FileManager.default.fileExists(atPath: expected.path))

    let firstMtime = try mtime(of: expected)

    // Run again — output should be byte-identical and mtime preserved (idempotent).
    try runCLI(executable: executable, config: configPath, source: sourcesDir, output: outputDir)

    let secondMtime = try mtime(of: expected)
    #expect(firstMtime == secondMtime)
}

private func productsURL() -> URL {
    let testBundle = Bundle.module.bundleURL
    return testBundle.deletingLastPathComponent() // .../debug/
}

private func runCLI(
    executable: URL,
    config: URL,
    source: URL,
    output: URL,
    includePackages: [String] = [],
) throws {
    let process = Process()
    process.executableURL = executable
    var args = [
        "--config", config.path,
        "--source", source.path,
        "--output", output.path,
    ]
    for pkg in includePackages {
        args.append("--include-package")
        args.append(pkg)
    }
    process.arguments = args
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: data, encoding: .utf8) ?? ""
        Issue.record("CLI failed: \(msg)")
    }
}

private func mtime(of url: URL) throws -> Date {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return attrs[.modificationDate] as? Date ?? .distantPast
}
