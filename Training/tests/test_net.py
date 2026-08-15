import pytest
import torch

from model import net, prep


def test_symbol_net_default_num_classes_matches_the_frozen_vocabulary():
    # `net.SymbolNet`'s `num_classes: int = 62` default is NOT sourced
    # from `prep.VOCABULARY` (the module deliberately does not import
    # `prep` — a detector architecture module has no business depending
    # on the label vocabulary module). Nothing else pins the two
    # together, so an append to `prep.VOCABULARY` — the frozen
    # trainable-class table — would silently drift out of sync with the
    # heatmap head's channel count with no error anywhere. This test
    # (not `net.py` itself) is what should go loud in that case.
    assert net.SymbolNet().heatmap_head.out_channels == len(prep.VOCABULARY)


def test_the_heads_are_stride_four_and_the_right_width():
    model = net.SymbolNet(num_classes=62, width=16)
    hm, off, geom = model(torch.zeros(2, 1, 128, 128))
    assert hm.shape == (2, 62, 32, 32)
    assert off.shape == (2, 2, 32, 32)
    assert geom.shape == (2, 4, 32, 32)


def test_the_heatmap_bias_starts_the_model_confident_that_most_cells_are_empty():
    # A CenterNet bias of -2.19 puts the initial probability near 0.1;
    # without it the focal loss spends its first epochs undoing a 0.5
    # prior over 62 classes x every cell.
    model = net.SymbolNet()
    assert model.heatmap_head.bias.detach().mean().item() == pytest.approx(-2.19, abs=1e-6)


def test_the_export_wrapper_emits_probabilities():
    wrapped = net.ExportWrapper(net.SymbolNet(num_classes=3, width=8))
    hm, _, _ = wrapped(torch.zeros(1, 1, 64, 64))
    assert float(hm.min()) >= 0.0 and float(hm.max()) <= 1.0
