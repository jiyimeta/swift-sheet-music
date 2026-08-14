import pytest
import torch

from model import losses


def test_focal_loss_is_zero_for_a_perfect_prediction():
    target = torch.zeros(1, 2, 4, 4); target[0, 1, 2, 2] = 1.0
    logits = torch.full_like(target, -20.0); logits[0, 1, 2, 2] = 20.0
    assert float(losses.focal(logits, target)) == pytest.approx(0.0, abs=1e-4)


def test_focal_loss_punishes_a_false_positive_less_near_a_peak_than_far_from_one():
    # Neither target has any target == 1 cell, so this stays entirely in
    # the negative branch of `focal` — the `(1 - target) ** 4` term is
    # the only thing that can produce a difference here. `logits` is a
    # uniform +20 everywhere: a confident false positive at every cell.
    # `soft` has one cell just outside a Gaussian peak (target == 0.8);
    # `hard_background` is pure background (target == 0) everywhere. The
    # false positive at the soft cell must cost less than the same false
    # positive on pure background — that differential is the entire
    # reason this loss survives the corpus's extreme class imbalance
    # (noteheadBlack 55,675x vs. the rarest class 16x, per a 600-page
    # sample).
    logits = torch.full((1, 1, 4, 4), 20.0)
    soft = torch.zeros(1, 1, 4, 4)
    soft[0, 0, 1, 1] = 0.8
    hard_background = torch.zeros(1, 1, 4, 4)
    assert (float(losses.focal(logits, soft))
            < float(losses.focal(logits, hard_background)))


def test_masked_l1_ignores_everything_outside_the_mask():
    pred = torch.ones(1, 4, 3, 3) * 5
    target = torch.zeros(1, 4, 3, 3)
    mask = torch.zeros(1, 1, 3, 3); mask[0, 0, 1, 1] = 1
    assert float(losses.masked_l1(pred, target, mask)) == pytest.approx(5.0)
