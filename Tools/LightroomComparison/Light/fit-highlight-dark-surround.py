"""Calibrate the fraction of negative Highlights loss retained in dark surroundings."""
import argparse
from collections import Counter
import hashlib
from itertools import product
import json
from pathlib import Path

import numpy as np

from error_metrics import nearest_rank


def p95(error):
    return nearest_rank(np.max(np.abs(error), axis=1), .95)


def source_scores(directory, row, probe_strength, candidates, subtract_source):
    """Predict each candidate from the same registered public GPU probe and Adobe pair."""
    path = directory / row['file']
    with path.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
            raise ValueError(f'Changed calibration capture {path}')
    with np.load(path, allow_pickle=False) as sample:
        indices = sample['idx']
        if str(sample['source']) != row['source'] or len(np.unique(indices)) != len(indices) or len(indices) < 2:
            raise ValueError(f'Invalid source or sample positions in {path}')
        source, native, probe, reference, neutral = (
            sample[key] for key in ('input', 'native', 'probe', 'target', 'neutral'))
        scene = sample['globalDark']
        near = sample['near']
    if (any(rgb.shape != (len(indices), 3) or not np.isfinite(rgb).all()
            for rgb in (source, native, probe, reference, neutral))
            or any(v.shape != (len(indices),) or not np.isfinite(v).all() for v in (near, scene))):
        raise ValueError(f'Invalid registered pixel values in {path}')
    residual = (native - source) - (reference - neutral)
    unit_change = (probe - native) / probe_strength
    width = np.ptp(np.clip(source, 0, 1), axis=1)
    scene = np.clip(scene / .125, 0, 1)
    dark_scene = scene * scene * (3 - 2 * scene)
    y = np.clip(source, 0, 1) @ np.array([.22897456, .69173852, .07928692])
    code = np.where(y <= .0031308, y * 12.92, 1.055 * np.maximum(y, 0) ** (1 / 2.4) - .055)
    source_dark = np.maximum(0, .5 - code)
    baseline = np.array([p95(residual[::2]), p95(residual[1::2])])
    scores = []
    for (chroma_span, color_gain, gray_gain), subtracted in zip(candidates, subtract_source, strict=True):
        color = np.clip(width / chroma_span, 0, 1)
        gain = color_gain * color + gray_gain * (1 - color) * dark_scene
        if subtracted:
            gain *= np.clip(1 - subtracted * source_dark / np.maximum(near, 1e-8), 0, 1)
        predicted = residual + unit_change * gain[:, None]
        scores.append(np.array([p95(predicted[::2]), p95(predicted[1::2])]) - baseline)
    return scores


def fit(path):
    manifest = json.loads(path.read_text())
    strength = manifest['probeStrength']
    if (manifest['control'] != 'Highlights2012' or manifest['amount'] != -50
            or not np.isfinite(strength) or not 0 < strength <= 1):
        raise ValueError('Expected a measured dark-surround probe at Highlights −50')
    rows = manifest['sources']
    families = np.array([row['family'] for row in rows])
    weights = {'photo': .55, 'chart': .30, 'cube': .15}
    if (set(families) != set(weights) or len(set(row['source'] for row in rows)) != len(rows)
            or any(row['settings']['id'] != row['id'] or row['settings']['source'] != row['source'] for row in rows)):
        raise ValueError('Expected unique registered photographs, spatial charts and a color lattice')
    candidates = list(product((.0625, .125, .25, .5), (0., .25, .5, .75, 1.), np.linspace(0, .6, 4)))
    def cost(changes, included):
        weighted = np.zeros(len(rows))
        for family, weight in weights.items():
            members = included & (families == family)
            if members.any():
                weighted[members] = weight / members.sum()
        return weighted @ (changes + np.maximum(changes, 0)) + .09 * changes[included].max(axis=0)

    every = np.ones(len(rows), dtype=bool)
    scores = np.array([source_scores(path.parent, row, strength, candidates, [0.] * len(candidates)) for row in rows])
    chosen = np.argmin(cost(scores[:, :, 0], every))
    span, color, gray = candidates[chosen]
    # Remove the source pixel's own contribution before interpreting darkness as
    # a surrounding field. The same reserved pixels and whole-source splits apply.
    fractions = (0., .25, .5, .75, 1.)
    scores = np.array([source_scores(path.parent, row, strength, [(span, color, gray)] * len(fractions), fractions)
                       for row in rows])
    chosen = np.argmin(cost(scores[:, :, 0], every))
    folds = [np.argmin(cost(scores[:, :, 0], np.arange(len(rows)) != i)) for i in range(len(rows))]
    held = scores[np.arange(len(rows)), folds, 1]
    return dict(chromaSpan=span, colorGain=color, grayGain=gray, sources=dict(Counter(families)),
                subtractedSourceDarkness=fractions[chosen], foldsWithSameSubtraction=folds.count(chosen),
                heldSourceScoreAtSelectedGains=cost(held, every),
                heldSourceChangesAtSelectedGains=dict(zip((r['id'] for r in rows), held)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
