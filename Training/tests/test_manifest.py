import json
import shutil
from pathlib import Path

from generate import manifest


def _fixture_dataset(root: Path) -> None:
    render = root / "cov_ties_ms4_Leland_v0"
    render.mkdir(parents=True)
    (render / "render.json").write_text(json.dumps({
        "schema": 1, "render_id": render.name, "source": "source.mscx",
        "pdf": "score.pdf", "engine": "ms4", "face": "ms4/Leland",
        "dpi": 300, "seed": 11,
    }, indent=2, sort_keys=True))
    (render / "page_0.labels.json").write_text(json.dumps({
        "schema": 1,
        "page": {"index": 0, "width_pt": 595.0, "height_pt": 842.0},
        "image": {"file": "page_0.png", "dpi": 300,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": [{"class": "noteheadBlack", "bbox_pt": [10, 10, 16, 15],
                    "origin_pt": [10.0, 12.5], "advance_pt": 6.0,
                    "rendered_size_pt": 5.0, "font_size_pt": 100.0}],
        "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {"noteheadBlack": 1}, "texts": 0},
    }, indent=2, sort_keys=True))


def test_build_verify_roundtrip(tmp_path):
    _fixture_dataset(tmp_path)
    m = manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={"ms4": "MuseScore 4.4.2"},
        renderer="pypdfium2 4.30.0", generator_commit="abc123",
        quarantined=[],
    )
    manifest.write_manifest(tmp_path, m)
    assert manifest.verify_manifest(tmp_path) == []
    assert m["class_counts"]["noteheadBlack"] == 1
    assert m["page_count"] == 1
    assert m["renders"][0]["face"] == "ms4/Leland"


def test_verify_detects_label_tampering(tmp_path):
    _fixture_dataset(tmp_path)
    manifest.write_manifest(tmp_path, manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    label = tmp_path / "cov_ties_ms4_Leland_v0" / "page_0.labels.json"
    label.write_text(label.read_text().replace("noteheadBlack", "noteheadHalf"))
    problems = manifest.verify_manifest(tmp_path)
    assert problems and "sha256" in problems[0]


def test_verify_detects_missing_label_file(tmp_path):
    """Discriminating in the OTHER direction from tampering: a label file
    that vanished entirely (not just changed content) must also surface,
    with a distinct reason string from a hash mismatch."""
    _fixture_dataset(tmp_path)
    manifest.write_manifest(tmp_path, manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    label = tmp_path / "cov_ties_ms4_Leland_v0" / "page_0.labels.json"
    label.unlink()
    problems = manifest.verify_manifest(tmp_path)
    assert problems and "missing" in problems[0]


def test_verify_reports_a_malformed_manifest_instead_of_raising(tmp_path):
    """The malformed-manifest guard (whole-branch review, Minor 3: the
    one branch of `verify_manifest` nothing covered). Its caller is a
    reporting path -- `finalize`'s `P3c-G1-selfcheck` line -- so a
    truncated `manifest.json` must come back as a named problem, not as
    a `JSONDecodeError` out of the middle of finalize."""
    _fixture_dataset(tmp_path)
    manifest.write_manifest(tmp_path, manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    path = tmp_path / "manifest.json"
    path.write_text(path.read_text()[:40])  # truncated mid-object

    problems = manifest.verify_manifest(tmp_path)
    assert len(problems) == 1
    assert problems[0].startswith("manifest unreadable:")


def test_verify_reports_an_absent_manifest_instead_of_raising(tmp_path):
    """The other half of the same guard: no `manifest.json` at all (a
    root that was never finalized) is a problem, not an OSError, and is
    distinguishable from "every label went missing"."""
    _fixture_dataset(tmp_path)
    assert not (tmp_path / "manifest.json").exists()

    problems = manifest.verify_manifest(tmp_path)
    assert len(problems) == 1
    assert problems[0].startswith("manifest unreadable:")


def test_compare_datasets_reports_byte_identity(tmp_path):
    a = tmp_path / "a"
    _fixture_dataset(a)
    manifest.write_manifest(a, manifest.build_manifest(
        a, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    b = tmp_path / "b"
    shutil.copytree(a, b)
    assert manifest.compare_datasets(a, b) == []
    label = b / "cov_ties_ms4_Leland_v0" / "page_0.labels.json"
    label.write_text(label.read_text().replace("12.5", "12.6"))
    assert manifest.compare_datasets(a, b) != []


def test_compare_datasets_detects_a_render_present_in_only_one_side(tmp_path):
    """A structural difference (an extra/missing render directory) must be
    reported too, not just per-file byte differences -- a dataset that
    regenerated with one extra render is not byte-identical even though
    every file that DOES exist on both sides matches."""
    a = tmp_path / "a"
    _fixture_dataset(a)
    manifest.write_manifest(a, manifest.build_manifest(
        a, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    b = tmp_path / "b"
    shutil.copytree(a, b)
    manifest.write_manifest(b, manifest.build_manifest(
        b, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    assert manifest.compare_datasets(a, b) == []

    extra = b / "extra_render_v0"
    extra.mkdir()
    (extra / "render.json").write_text(json.dumps({
        "schema": 1, "render_id": extra.name, "source": "source.mscx",
        "pdf": "score.pdf", "engine": "ms4", "face": "ms4/Bravura",
        "dpi": 300, "seed": 12,
    }, indent=2, sort_keys=True))
    (extra / "page_0.labels.json").write_text(json.dumps({
        "schema": 1,
        "page": {"index": 0, "width_pt": 595.0, "height_pt": 842.0},
        "image": {"file": "page_0.png", "dpi": 300,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": [], "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {}, "texts": 0},
    }, indent=2, sort_keys=True))
    manifest.write_manifest(b, manifest.build_manifest(
        b, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[]))
    problems = manifest.compare_datasets(a, b)
    assert problems
    assert any("extra_render_v0" in p for p in problems)


def test_coverage_report_flags_classes_below_floor(tmp_path):
    _fixture_dataset(tmp_path)
    m = manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[], class_floor=2)
    report = manifest.coverage_report(m)
    assert any(line.startswith("noteheadBlack ") for line in report)  # 1 < 2
    assert any(line.startswith("clefG ") for line in report)          # 0 < 2


def test_coverage_report_omits_no_class_above_floor(tmp_path):
    """Discriminating in the other direction: raise the floor to 0 (every
    class trivially clears it) and the report must be empty, not just
    "non-empty is fine"."""
    _fixture_dataset(tmp_path)
    m = manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={}, renderer="r",
        generator_commit="c", quarantined=[], class_floor=0)
    assert manifest.coverage_report(m) == []


def test_build_manifest_is_byte_identical_across_regenerations(tmp_path):
    """The determinism contract itself (P3c-G1): rebuilding a manifest
    from the SAME on-disk dataset twice must serialize to identical
    bytes, independent of directory-listing order."""
    _fixture_dataset(tmp_path)
    m1 = manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={"ms4": "MuseScore 4.4.2"},
        renderer="r", generator_commit="c", quarantined=[])
    m2 = manifest.build_manifest(
        tmp_path, dataset_seed=11, engines={"ms4": "MuseScore 4.4.2"},
        renderer="r", generator_commit="c", quarantined=[])
    # Compare the exact bytes write_manifest would produce (sort_keys=True).
    b1 = json.dumps(m1, indent=2, sort_keys=True)
    b2 = json.dumps(m2, indent=2, sort_keys=True)
    assert b1 == b2
