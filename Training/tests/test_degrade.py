"""Tests for the degradation chain (spec §6.5). See `Training/generate/degrade.py`
for the stage contract: `(image uint8 HxW, rng, params) -> (image, homography|None)`.

Beyond the plan's baseline coverage, this file directly verifies the plan's
single most load-bearing promise -- that the per-page `label_transform` is
the genuine matrix composition of each geometric stage's homography, not
merely "a 3x3 matrix is present" -- and that the phone-photo extension point
(a sibling profile adding a new geometric stage) needs zero change to
`load_profile` / `apply_chain`.
"""

import hashlib
import json
from pathlib import Path

import numpy as np
import pypdfium2 as pdfium
from PIL import Image

from generate import degrade, rasterize

PROFILE = Path(__file__).resolve().parents[1] / "generate" / "profiles" / "scanner.toml"


def _page(tmp_path) -> np.ndarray:
    doc = pdfium.PdfDocument.new()
    doc.new_page(200, 200)
    pdf = tmp_path / "s.pdf"
    doc.save(str(pdf))
    png = rasterize.rasterize_pdf(pdf, tmp_path, dpi=72)[0]
    return np.asarray(Image.open(png), dtype=np.uint8)


def _labels_json() -> dict:
    return {
        "schema": 1,
        "page": {"index": 0, "width_pt": 200.0, "height_pt": 200.0},
        "image": {"file": "page_0.png", "dpi": 72,
                  "label_transform": [1, 0, 0, 0, 1, 0, 0, 0, 1]},
        "glyphs": [], "paths": [], "beams": [], "curves": [], "texts": [],
        "census": {"glyphs_by_class": {}, "texts": 0},
    }


def test_profile_loads_ordered_stages():
    profile = degrade.load_profile(PROFILE)
    names = [name for name, _ in profile]
    assert names[0] == "resample"
    assert "rotate" in names and "jpeg_roundtrip" in names
    assert "annotation_overlay" in names
    assert all(name in degrade.STAGES for name in names)


def test_chain_is_deterministic_per_seed(tmp_path):
    img = _page(tmp_path)
    profile = degrade.load_profile(PROFILE)
    a, ha = degrade.apply_chain(img, profile, np.random.default_rng(5))
    b, hb = degrade.apply_chain(img, profile, np.random.default_rng(5))
    assert np.array_equal(a, b)
    assert np.array_equal(ha, hb)
    c, _ = degrade.apply_chain(img, profile, np.random.default_rng(6))
    assert not np.array_equal(a, c)


def test_rotate_stage_returns_its_homography():
    img = np.full((100, 100), 255, dtype=np.uint8)
    rng = np.random.default_rng(1)
    out, h = degrade.STAGES["rotate"](img, rng, {"max_deg": 2.0})
    assert h is not None and h.shape == (3, 3)
    # Bottom row of an affine homography.
    assert np.allclose(h[2], [0, 0, 1])


def test_geometric_stages_always_return_a_transform():
    """Every geometric stage MUST contribute a homography, every time --
    not just "sometimes", the way the photometric stages' probabilistic
    no-op branches do. A geometric stage that silently returned None on
    some draw would corrupt that page's label_transform with no error."""
    img = np.full((80, 80), 255, dtype=np.uint8)
    cases = [
        ("resample", {"scale_lo": 0.9, "scale_hi": 1.1, "aniso_max": 0.02}),
        ("rotate", {"max_deg": 2.0}),
    ]
    for name, params in cases:
        for seed in range(5):
            rng = np.random.default_rng(seed)
            out, h = degrade.STAGES[name](img, rng, params)
            assert h is not None, (name, seed)
            assert h.shape == (3, 3), name
            assert np.allclose(h[2], [0, 0, 1]), name


def test_photometric_stages_return_no_transform():
    img = np.full((60, 60), 200, dtype=np.uint8)
    rng = np.random.default_rng(1)
    for name in ["gaussian_blur", "noise", "illumination_gradient",
                 "threshold", "jpeg_roundtrip", "erode_dilate",
                 "bleed_through", "annotation_overlay"]:
        out, h = degrade.STAGES[name](img, rng, {})
        assert h is None, name
        assert out.dtype == np.uint8 and out.ndim == 2, name


def test_composition_is_the_product_of_stage_homographies_in_order():
    """The composition rule IS the deliverable: apply_chain must compose
    each geometric stage's homography as `h_total = h_stage_k @ ... @
    h_stage_1` (later stage's matrix on the left), so that applying
    h_total to a point in the ORIGINAL image lands exactly where applying
    each stage's transform in turn, one at a time, would land it.

    This test uses two synthetic stages with hand-picked, non-commuting
    parameters (translate-then-scale != scale-then-translate) so an
    identity-composition bug or a reversed multiplication order would be
    caught, and checks the result against arithmetic computed independently
    of degrade._affine / apply_chain's own matrix machinery."""
    def _translate_stage(img, rng, p):
        tx, ty = p["tx"], p["ty"]
        h = degrade._affine(1, 0, tx, 0, 1, ty)
        return img, h

    def _scale_stage(img, rng, p):
        s = p["s"]
        h = degrade._affine(s, 0, 0, 0, s, 0)
        return img, h

    original_stages = dict(degrade.STAGES)
    degrade.STAGES["_test_translate"] = _translate_stage
    degrade.STAGES["_test_scale"] = _scale_stage
    try:
        profile = [("_test_translate", {"tx": 10.0, "ty": 5.0}),
                   ("_test_scale", {"s": 2.0})]
        img = np.full((40, 40), 255, dtype=np.uint8)
        _, h_total = degrade.apply_chain(img, profile, np.random.default_rng(0))

        x0, y0 = 1.0, 1.0
        got = h_total @ np.array([x0, y0, 1.0])

        # Independent geometry: translate THEN scale, plain arithmetic,
        # no matrices at all.
        x1, y1 = x0 + 10.0, y0 + 5.0
        expected = (x1 * 2.0, y1 * 2.0)
        assert np.allclose(got[:2], expected)
        assert np.isclose(got[2], 1.0)

        # And the reverse order must NOT match (proves this isn't a
        # coincidence of commuting operations / an identity bug).
        reverse_profile = [("_test_scale", {"s": 2.0}),
                            ("_test_translate", {"tx": 10.0, "ty": 5.0})]
        _, h_reverse = degrade.apply_chain(img, reverse_profile, np.random.default_rng(0))
        got_reverse = h_reverse @ np.array([x0, y0, 1.0])
        assert not np.allclose(got_reverse[:2], expected)
    finally:
        degrade.STAGES.clear()
        degrade.STAGES.update(original_stages)


def test_new_geometric_stage_composes_through_unmodified_machinery(tmp_path, monkeypatch):
    """The phone-photo extension point: a future profile lists a brand-new
    geometric stage (e.g. `perspective_warp`). Simulate that here with a
    throwaway stub stage and a hand-written sibling .toml -- `load_profile`
    and `apply_chain` are used completely unmodified. If this passes, the
    plan's "no code path changes shape" promise is real, not aspirational."""
    def _perspective_stub(img, rng, p):
        tx = p.get("tx", 0.0)
        h = degrade._affine(1, 0, tx, 0, 1, 0)
        return img, h

    monkeypatch.setitem(degrade.STAGES, "perspective_stub", _perspective_stub)

    profile_path = tmp_path / "phone_stub.toml"
    profile_path.write_text(
        '[[stage]]\nname = "rotate"\nmax_deg = 0.0\n\n'
        '[[stage]]\nname = "perspective_stub"\ntx = 7.0\n'
    )

    profile = degrade.load_profile(profile_path)
    assert [name for name, _ in profile] == ["rotate", "perspective_stub"]

    img = np.full((50, 50), 255, dtype=np.uint8)
    _, h_total = degrade.apply_chain(img, profile, np.random.default_rng(3))

    # rotate with max_deg=0.0 is the identity rotation (rng draws 0 from a
    # zero-width range), so the composition should reduce to the stub's
    # pure x-translation by 7.
    got = h_total @ np.array([4.0, 4.0, 1.0])
    assert np.allclose(got, [11.0, 4.0, 1.0])


def test_freeze_eval_page_rewrites_only_transform_and_file(tmp_path):
    _page(tmp_path)  # writes page_0.png into tmp_path via rasterize_pdf
    png = tmp_path / "page_0.png"
    labels = tmp_path / "page_0.labels.json"
    labels.write_text(json.dumps(_labels_json(), indent=2, sort_keys=True))
    out_dir = tmp_path / "frozen"
    degrade.freeze_eval_page(png, labels, out_dir,
                             degrade.load_profile(PROFILE),
                             np.random.default_rng(9))
    frozen = json.loads((out_dir / "page_0.labels.json").read_text())
    assert frozen["image"]["label_transform"] != [1, 0, 0, 0, 1, 0, 0, 0, 1]
    assert (out_dir / frozen["image"]["file"]).exists()
    # Everything except image.file / image.label_transform is untouched.
    original = json.loads(labels.read_text())
    original["image"].pop("file"); original["image"].pop("label_transform")
    frozen["image"].pop("file"); frozen["image"].pop("label_transform")
    assert original == frozen


def test_freeze_eval_page_is_byte_identical_across_regenerations(tmp_path):
    """P3c-G1: regenerating a frozen eval page with the same seed must
    yield byte-identical image bytes and label text, not just
    "equivalent" JSON -- the manifest/labels are compared as files."""
    _page(tmp_path)  # writes page_0.png into tmp_path via rasterize_pdf
    png = tmp_path / "page_0.png"
    labels = tmp_path / "page_0.labels.json"
    labels.write_text(json.dumps(_labels_json(), indent=2, sort_keys=True))

    profile = degrade.load_profile(PROFILE)
    out_a, out_b = tmp_path / "frozen_a", tmp_path / "frozen_b"
    degrade.freeze_eval_page(png, labels, out_a, profile, np.random.default_rng(42))
    degrade.freeze_eval_page(png, labels, out_b, profile, np.random.default_rng(42))

    bytes_a = (out_a / "page_0.png").read_bytes()
    bytes_b = (out_b / "page_0.png").read_bytes()
    assert hashlib.sha256(bytes_a).digest() == hashlib.sha256(bytes_b).digest()
    assert (out_a / "page_0.labels.json").read_text() == (out_b / "page_0.labels.json").read_text()


def test_threshold_stage_reads_profile_supplied_cut():
    """Regression: `stage_threshold`'s binarization bounds must come from
    the profile, like every other stage's parameters -- not be a value
    baked into the function. `p=1.0` forces the stage to always fire, so
    the effect of `thresh_lo`/`thresh_hi` is checked deterministically,
    not merely that the keys are accepted without error."""
    img = np.array([[100, 150]], dtype=np.uint8)

    # Default range (120, 200): a pixel valued 100 can never exceed the
    # draw (draw is always >= 120), so it MUST binarize to 0.
    out_default, _ = degrade.STAGES["threshold"](img, np.random.default_rng(0), {"p": 1.0})
    assert out_default[0, 0] == 0

    # Profile-supplied cut of exactly 50 (thresh_lo == thresh_hi pins the
    # draw): both 100 and 150 exceed it, so both MUST binarize to 255 --
    # the opposite of the default-range outcome above. This can only
    # happen if the override actually reached rng.uniform(...), not just
    # parsed without error.
    out_override, _ = degrade.STAGES["threshold"](
        img, np.random.default_rng(0), {"p": 1.0, "thresh_lo": 50, "thresh_hi": 50})
    assert out_override[0, 0] == 255
    assert out_override[0, 1] == 255


def test_erode_dilate_stage_reads_profile_supplied_element_size():
    """Regression: `stage_erode_dilate`'s structuring element must come
    from the profile too. `p_erode=1.0, p_dilate=0.0` forces the erosion
    branch deterministically, so a larger `elem_size` must spread the
    single dark pixel further than the default 2x2 element does --
    proving the override changed the actual filter, not just that the
    key parsed."""
    img = np.full((20, 20), 255, dtype=np.uint8)
    img[10, 10] = 0

    out_default, h_default = degrade.STAGES["erode_dilate"](
        img, np.random.default_rng(0), {"p_erode": 1.0, "p_dilate": 0.0})
    out_bigger, h_bigger = degrade.STAGES["erode_dilate"](
        img, np.random.default_rng(0), {"p_erode": 1.0, "p_dilate": 0.0, "elem_size": 6})

    assert h_default is None and h_bigger is None
    default_dark_pixels = int(np.sum(out_default < 255))
    bigger_dark_pixels = int(np.sum(out_bigger < 255))
    assert bigger_dark_pixels > default_dark_pixels


def test_scanner_profile_pins_the_preserved_defaults():
    """The new `elem_size` / `thresh_lo` / `thresh_hi` keys added to
    scanner.toml must equal the values that used to be hardcoded, so
    previously-recorded seeds against this profile still reproduce the
    same output (the property P3c-G1's byte-identity gate depends on)."""
    profile = dict(degrade.load_profile(PROFILE))
    assert profile["erode_dilate"]["elem_size"] == 2
    assert profile["threshold"]["thresh_lo"] == 120
    assert profile["threshold"]["thresh_hi"] == 200
