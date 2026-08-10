"""Dataset manifest (spec §6.7): the reproducibility contract. Same seed
+ same manifest => byte-identical labels + manifest on one host
(gate P3c-G1, checked by compare_datasets). Per-class counts feed the
coverage floor gate (P3c-G3).

Determinism: every pass over the filesystem is sorted explicitly
(`_render_dirs`, `sorted(render_dir.glob(...))`, `sorted(...)` over dict
keys wherever iteration order feeds output) -- directory-listing order is
never trusted, and `class_counts` is built by iterating
`vocabulary.CLASS_NAMES` (a fixed list), not by discovering keys from
whatever order labels happen to declare them in. `write_manifest` always
serializes with `sort_keys=True`, so the manifest's own key order can
never depend on dict-construction order either.
"""

import hashlib
import json
from pathlib import Path

from generate import vocabulary

SCHEMA = 1


def sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _render_dirs(root: Path) -> list[Path]:
    return sorted(
        p for p in Path(root).iterdir()
        if p.is_dir() and (p / "render.json").exists()
    )


def build_manifest(root: Path, *, dataset_seed: int, engines: dict[str, str],
                   renderer: str, generator_commit: str,
                   quarantined: list[dict], class_floor: int = 1000) -> dict:
    """Walk `root`'s render directories (each one identified by owning a
    `render.json`) and assemble the manifest dict. Per-source status is
    "exported" (has at least one page label) or "no-labels" (a render
    directory exists but produced none -- visible rather than silently
    absent from the manifest). `class_counts` covers exactly the 64
    detector classes in `vocabulary.CLASS_NAMES` (RESERVED classes like
    `stem` / `staff5Lines` are not detector targets and are not counted
    here), every one initialized to 0 so a class with zero instances
    anywhere in the dataset is a visible `0`, not a missing key.
    """
    renders = []
    class_counts = {name: 0 for name in vocabulary.CLASS_NAMES}
    page_count = 0
    label_hashes = {}
    for render_dir in _render_dirs(root):
        render = json.loads((render_dir / "render.json").read_text())
        labels = sorted(render_dir.glob("page_*.labels.json"))
        page_count += len(labels)
        for label_path in labels:
            rel = f"{render_dir.name}/{label_path.name}"
            label_hashes[rel] = sha256_file(label_path)
            doc = json.loads(label_path.read_text())
            for cls, n in doc["census"]["glyphs_by_class"].items():
                if cls in class_counts:
                    class_counts[cls] += n
        renders.append({
            "render_id": render_dir.name,
            "face": render.get("face", ""),
            "engine": render.get("engine", ""),
            "dpi": render.get("dpi", 0),
            "pages": len(labels),
            "status": "exported" if labels else "no-labels",
        })
    return {
        "schema": SCHEMA,
        "dataset_seed": dataset_seed,
        "generator_commit": generator_commit,
        "engines": engines,           # engine id -> `mscore --version` output
        "renderer": renderer,
        "class_floor": class_floor,
        "class_counts": class_counts,
        "page_count": page_count,
        "renders": renders,
        "quarantined": quarantined,
        "label_sha256": label_hashes,
    }


def write_manifest(root: Path, manifest: dict) -> Path:
    path = Path(root) / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return path


def verify_manifest(root: Path) -> list[str]:
    """Re-hash every label file `root/manifest.json` lists and compare
    against the recorded sha256. `[]` means clean. Distinguishes a
    vanished file ("missing") from a changed one ("sha256 mismatch") so a
    caller/log reader can tell the two failure modes apart, and iterates
    `sorted(...)` so the returned problem list has a deterministic order
    independent of the manifest's own (already sorted-on-write) dict
    order.

    Called by `build_dataset.finalize_dataset` immediately after writing
    the manifest (the `P3c-G1-selfcheck` line): two-root byte identity
    only means something if each manifest describes the dataset sitting
    next to it. An unreadable or malformed manifest is itself a problem
    rather than an exception -- the caller is a reporting path, and a
    truncated `manifest.json` must be named, not raised through."""
    root = Path(root)
    manifest_path = root / "manifest.json"
    try:
        text = manifest_path.read_text()
    except OSError as e:
        return [f"manifest unreadable: {e}"]
    try:
        manifest = json.loads(text)
    except json.JSONDecodeError as e:
        return [f"manifest unreadable: {e}"]
    problems = []
    for rel, expected in sorted(manifest.get("label_sha256", {}).items()):
        path = root / rel
        if not path.exists():
            problems.append(f"{rel}: missing")
        elif sha256_file(path) != expected:
            problems.append(f"{rel}: sha256 mismatch")
    return problems


def compare_datasets(a: Path, b: Path) -> list[str]:
    """Byte-identity of labels + manifest between two roots (P3c-G1).
    Images are excluded by design (same-host identity is expected but not
    the contract). Genuinely discriminating in both directions: a label
    file present in one root's manifest but not the other's (a
    regeneration that dropped or added a render) is reported just as
    surely as one whose bytes changed -- comparing only `a`'s key set
    against `b` would silently miss a render `b` has that `a` doesn't."""
    a, b = Path(a), Path(b)
    ma_path, mb_path = a / "manifest.json", b / "manifest.json"
    if not ma_path.exists():
        return [f"manifest.json: missing in {a}"]
    if not mb_path.exists():
        return [f"manifest.json: missing in {b}"]

    problems = []
    if sha256_file(ma_path) != sha256_file(mb_path):
        problems.append("manifest.json: differs")

    ma = json.loads(ma_path.read_text())
    mb = json.loads(mb_path.read_text())
    hashes_a = ma.get("label_sha256", {})
    hashes_b = mb.get("label_sha256", {})
    for rel in sorted(set(hashes_a) | set(hashes_b)):
        in_a, in_b = rel in hashes_a, rel in hashes_b
        if in_a and not in_b:
            problems.append(f"{rel}: present in {a} only")
            continue
        if in_b and not in_a:
            problems.append(f"{rel}: present in {b} only")
            continue
        pa, pb = a / rel, b / rel
        if not pa.exists():
            problems.append(f"{rel}: missing file in {a}")
        elif not pb.exists():
            problems.append(f"{rel}: missing file in {b}")
        elif sha256_file(pa) != sha256_file(pb):
            problems.append(f"{rel}: differs")
    return problems


def coverage_shortfalls(manifest: dict) -> list[str]:
    """Class names below the per-class floor (gate P3c-G3), sorted, and
    EXCLUDING the classes nothing can draw.

    `class_counts` was seeded with every vocabulary class at 0 in
    `build_manifest`, so a class with zero instances anywhere in the
    dataset appears here explicitly rather than being silently absent
    because no label ever mentioned it -- which is the whole point, and
    is also why the exemption has to be subtracted deliberately instead
    of being allowed to look like a shortfall forever. See
    `vocabulary.UNREACHABLE` for what is exempt and why.
    """
    floor = manifest["class_floor"]
    return sorted(
        cls for cls, n in manifest["class_counts"].items()
        if n < floor and cls not in vocabulary.UNREACHABLE
    )


def coverage_report(manifest: dict) -> list[str]:
    """`coverage_shortfalls` rendered as `"<class> <n>/<floor>"` lines,
    the form `finalize` prints."""
    floor = manifest["class_floor"]
    counts = manifest["class_counts"]
    return [f"{cls} {counts[cls]}/{floor}"
            for cls in coverage_shortfalls(manifest)]
