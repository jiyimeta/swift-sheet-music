import Foundation
import WireFormatKotlinEmitter
import WireFormatSchema

struct CLIArguments {
    var configPath: String
    var sourceDir: String
    var outputDir: String

    static func parse(_ argv: [String]) -> CLIArguments? {
        var config: String?
        var source: String?
        var output: String?
        var i = 1
        while i < argv.count {
            let key = argv[i]
            switch key {
            case "--config": config = argv[safe: i + 1]; i += 2
            case "--source": source = argv[safe: i + 1]; i += 2
            case "--output": output = argv[safe: i + 1]; i += 2
            default:
                fputs("Unknown argument: \(key)\n", stderr)
                return nil
            }
        }
        guard let c = config, let s = source, let o = output else { return nil }
        return CLIArguments(configPath: c, sourceDir: s, outputDir: o)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

guard let args = CLIArguments.parse(CommandLine.arguments) else {
    fputs("usage: emit-kotlin-codecs --config <file> --source <dir> --output <dir>\n", stderr)
    exit(2)
}

let configURL = URL(fileURLWithPath: args.configPath)
let configData = try Data(contentsOf: configURL)
let config = try JSONDecoder().decode(KotlinCodegenConfig.self, from: configData)

let sourceURL = URL(fileURLWithPath: args.sourceDir, isDirectory: true)
var aggregateSchema = Schema(types: [])
if let enumerator = FileManager.default.enumerator(
    at: sourceURL,
    includingPropertiesForKeys: [.isRegularFileKey],
) {
    for case let url as URL in enumerator {
        guard url.pathExtension == "swift" else { continue }
        let source = try String(contentsOf: url, encoding: .utf8)
        let schema = SchemaParser.parse(source: source, fileName: url.lastPathComponent)
        aggregateSchema.types.append(contentsOf: schema.types)
    }
}

let emitter = KotlinEmitter(config: config)
let files = try emitter.emit(schema: aggregateSchema)

let outputURL = URL(fileURLWithPath: args.outputDir, isDirectory: true)

/// Track generated files so we can prune deletions.
var generatedPaths = Set<String>()
for file in files {
    let dest = outputURL.appendingPathComponent(file.relativePath)
    try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    if let existing = try? String(contentsOf: dest, encoding: .utf8), existing == file.content {
        // Idempotent: skip rewriting unchanged file (preserves mtime).
    } else {
        try file.content.write(to: dest, atomically: true, encoding: .utf8)
    }
    generatedPaths.insert(dest.path)
}

// Sweep stale files: any .kt under outputDir that we didn't write this run.
if let sweep = FileManager.default.enumerator(at: outputURL, includingPropertiesForKeys: nil) {
    for case let url as URL in sweep {
        guard url.pathExtension == "kt", !generatedPaths.contains(url.path) else { continue }
        try? FileManager.default.removeItem(at: url)
    }
}
