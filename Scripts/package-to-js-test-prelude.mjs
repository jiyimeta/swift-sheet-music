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

export async function setupOptions(options) {
    const root = options.wasi.fds[3].dir;

    installPath(root, "/tmp", new Directory(new Map()));

    const resources = new Directory(new Map());
    copyDirectory(resourceRoot, resources);
    installPath(root, resourceRoot, resources);

    return options;
}
