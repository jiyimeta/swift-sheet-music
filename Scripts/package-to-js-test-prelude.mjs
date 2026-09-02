import {
    Directory,
    File,
} from "../.build/plugins/PackageToJS/outputs/PackageTests/node_modules/@bjorn3/browser_wasi_shim/dist/index.js";
import { lstatSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDirectory, "..");
const resourceRoot = path.resolve(
    repoRoot,
    ".build/wasm32-unknown-wasip1/debug/swift-sheet-music_SheetMusicTests.resources",
);

function ensureDirectory(parent, name) {
    const existing = parent.contents.get(name);
    if (existing instanceof Directory) {
        return existing;
    }
    const created = new Directory(new Map());
    parent.contents.set(name, created);
    return created;
}

function installPath(root, absolutePath, inode) {
    const parts = absolutePath.split(path.sep).filter(Boolean);
    let current = root;
    for (const part of parts.slice(0, -1)) {
        current = ensureDirectory(current, part);
    }
    current.contents.set(parts.at(-1), inode);
}

function copyDirectory(source, target) {
    for (const entry of readdirSync(source)) {
        const sourcePath = path.join(source, entry);
        const stat = lstatSync(sourcePath);
        if (stat.isDirectory()) {
            const child = ensureDirectory(target, entry);
            copyDirectory(sourcePath, child);
        } else if (stat.isFile()) {
            target.contents.set(entry, new File(readFileSync(sourcePath)));
        }
    }
}

/// Reports the process's wasm-backed memory as it grows, for diagnosing the out-of-bounds `dlmalloc` trap the
/// full suite hits.
///
/// Opt-in through `SHEET_MUSIC_WASM_MEMORY_TRACE=1`, so an ordinary run — CI's included — is unchanged.
///
/// Sampled from inside `fd_write` rather than from a timer: the wasm test run is one long synchronous call
/// (Swift Testing drives a cooperative executor that spins without yielding), so a `setInterval` never fires
/// until the run is already over. `fd_write` is what carries the test output, so it ticks with progress, and the
/// marker lands in the log between the tests that moved the number.
function traceMemoryGrowth(options) {
    if (process.env.SHEET_MUSIC_WASM_MEMORY_TRACE !== "1") {
        return;
    }
    const step = 16 * 1024 * 1024;
    let peakBytes = 0;
    const original = options.wasi.wasiImport.fd_write;
    options.wasi.wasiImport.fd_write = function (...args) {
        const result = original.apply(this, args);
        const usage = process.memoryUsage();
        // `arrayBuffers` is where a `WebAssembly.Memory`'s backing store is counted; `external` covers the rest
        // of what the shim holds on the wasm module's behalf.
        const bytes = usage.arrayBuffers + usage.external;
        if (bytes > peakBytes + step) {
            peakBytes = bytes;
            process.stderr.write(`[mem] ${(bytes / (1024 * 1024)).toFixed(0)} MiB\n`);
        }
        return result;
    };
}

export async function setupOptions(options) {
    traceMemoryGrowth(options);
    const root = options.wasi.fds[3].dir;

    installPath(root, "/tmp", new Directory(new Map()));

    const resources = new Directory(new Map());
    copyDirectory(resourceRoot, resources);
    installPath(root, resourceRoot, resources);

    return options;
}
