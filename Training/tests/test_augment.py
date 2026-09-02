import random

import numpy as np
import pytest

from model import augment


def _gradient(size: int = 32) -> np.ndarray:
    """A gradient, not a constant: a constant image is invariant under
    contrast AND gamma AND blur, so it cannot tell any of those apart from
    the identity."""
    y, x = np.mgrid[0:size, 0:size]
    return ((x + y) / (2.0 * (size - 1))).astype(np.float32)


def test_a_zero_probability_config_is_the_identity():
    # `--augment none` skips the call entirely, but the all-zero config is
    # what proves each probability really gates its own op — every op
    # below is switched on individually against this baseline.
    image = _gradient()
    out = augment.NONE.apply(image, random.Random(0))
    assert out is image or np.array_equal(out, image)


@pytest.mark.parametrize("field", ["contrast", "gamma", "blur", "noise", "speckle"])
def test_each_op_changes_the_image_when_it_alone_is_enabled(field):
    # One op at a time, at probability 1. Without this a config whose
    # dispatch dropped an op — a copy-pasted `if self.blur_p` guarding the
    # noise branch, say — would still pass a test that only checks "the
    # output differs from the input".
    image = _gradient()
    kwargs = {f"{f}_p": 0.0 for f in ["contrast", "gamma", "blur", "noise", "speckle"]}
    kwargs[f"{field}_p"] = 1.0
    if field == "blur":
        kwargs["blur_sigma"] = (0.8, 0.8)
    if field == "noise":
        kwargs["noise_sigma"] = (0.05, 0.05)
    if field == "speckle":
        kwargs["speckle_fraction"] = (0.05, 0.05)
    if field == "gamma":
        kwargs["gamma"] = (2.0, 2.0)
    if field == "contrast":
        kwargs["contrast_gain"] = (1.5, 1.5)
        kwargs["contrast_bias"] = (0.05, 0.05)
    cfg = augment.PhotometricAugment(**kwargs)

    out = cfg.apply(image, random.Random(0))
    assert not np.array_equal(out, image), f"{field} did not change the image"
    assert out.shape == image.shape
    assert out.dtype == np.float32
    assert 0.0 <= out.min() and out.max() <= 1.0


#: Every op forced on. Used wherever a test must exercise the branches
#: that draw from numpy rather than from `rng` directly — under the
#: DEFAULT probabilities those branches may simply not fire for the seed a
#: test happens to pick, and a test that never enters a branch cannot say
#: anything about it. (Measured: with the defaults, replacing the noise
#: branch's seeded generator with a global `np.random.default_rng()` left
#: the reproducibility test GREEN.)
_ALL_ON = augment.PhotometricAugment(
    contrast_p=1.0, gamma_p=1.0,
    blur_p=1.0, blur_sigma=(0.7, 0.7),
    noise_p=1.0, noise_sigma=(0.04, 0.04),
    speckle_p=1.0, speckle_fraction=(0.01, 0.01),
)


@pytest.mark.parametrize("cfg_name", ["default", "all_on"])
def test_the_same_rng_state_reproduces_the_same_output(cfg_name):
    # The whole augmentation must be a function of the passed RNG alone —
    # no module-level `np.random` calls, which would make a run
    # irreproducible and would not show up in any other assertion here.
    # The `all_on` arm is the one that actually pins it; the `default` arm
    # is kept because it is the configuration a real run uses.
    image = _gradient()
    cfg = augment.PhotometricAugment() if cfg_name == "default" else _ALL_ON
    a = cfg.apply(image, random.Random(1234))
    b = cfg.apply(image, random.Random(1234))
    assert np.array_equal(a, b)


def test_different_rng_states_give_different_output():
    # Anti-vacuity for the test above: if `apply` ignored the RNG and
    # returned a fixed transform, the reproducibility test would pass too.
    image = _gradient()
    cfg = augment.PhotometricAugment()
    outs = [cfg.apply(image, random.Random(seed)) for seed in range(6)]
    assert any(not np.array_equal(outs[0], o) for o in outs[1:])


@pytest.mark.parametrize("speckle_p", [1.0, 0.0])
def test_the_result_stays_in_range_under_extreme_parameters(speckle_p):
    # Contrast can push below 0 and gamma of a negative is nan; heavy
    # noise leaves the range outright. A nan reaching the model shows up
    # as a nan loss many minutes later with nothing pointing back here.
    #
    # The `speckle_p=0` arm exists because the speckle op happens to run
    # LAST and rebuilds its output from a clipped array, so with speckle
    # on it masks a missing final clip: deleting `np.clip` from the return
    # left the speckle-on arm GREEN. Turning speckle off makes additive
    # noise the last op, and then the final clip is load-bearing.
    image = _gradient()
    cfg = augment.PhotometricAugment(
        contrast_p=1.0, contrast_gain=(3.0, 3.0), contrast_bias=(-0.5, -0.5),
        gamma_p=1.0, gamma=(0.3, 0.3),
        blur_p=1.0, blur_sigma=(2.0, 2.0),
        noise_p=1.0, noise_sigma=(0.5, 0.5),
        speckle_p=speckle_p, speckle_fraction=(0.2, 0.2),
    )
    for seed in range(20):
        out = cfg.apply(image, random.Random(seed))
        assert np.isfinite(out).all(), f"non-finite output at seed {seed}"
        assert 0.0 <= out.min() and out.max() <= 1.0


def test_from_name_rejects_an_unknown_mode():
    assert augment.from_name("none") is None
    assert isinstance(augment.from_name("photometric"), augment.PhotometricAugment)
    with pytest.raises(ValueError, match="unknown --augment"):
        augment.from_name("gemoetric")
