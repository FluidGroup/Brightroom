"""Calibrate how strongly negative Highlights shares the measured loss of equal source tones."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from error_metrics import nearest_rank


def smooth(x):
    t = np.clip(x, 0, 1)
    return t * t * (3 - 2 * t)


def p95(rgb):
    return nearest_rank(np.max(np.abs(rgb), axis=1), .95)


def load(path):
    """Load each signed −50 pair and its 35% scene-loss probe once per calibration image."""
    manifest = json.loads(path.read_text())
    if manifest['control'] != 'Highlights2012' or manifest['amount'] != -50 or manifest['probe'] != .35:
        raise ValueError('Expected registered −50 Highlights and a 35% scene loss probe')
    rows = []
    sources = set()
    for case in manifest['samples']:
        if not case['training']:
            continue
        file = path.parent / case['file']
        with file.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != case['sample'] or case['source'] in sources:
            raise ValueError(f"Changed capture or duplicate calibration image {case['id']}")
        sources.add(case['source'])
        with np.load(file, allow_pickle=False) as capture:
            count = len(capture['idx'])
            if not count or len(np.unique(capture['idx'])) != count:
                raise ValueError(f'Empty or repeated spatial indices in {file}')
            x, n, old, t, probe = [capture[k].astype(float) for k in ('x', 'n', 'old', 't', 'e')]
            guide = capture['guide'].astype(float)
            if (any(v.shape != (count, 3) or not np.isfinite(v).all() for v in (x, n, old, t, probe))
                    or guide.shape != (count, 19) or not np.isfinite(guide).all()):
                raise ValueError(f'Invalid paired pixels or scene statistics in {file}')
        rgb = guide[:, :3]
        fine = np.clip(1 - (guide[:, 5] / np.maximum(guide[:, 4], 1e-8)) ** 2, 0, 1)
        region = np.clip(np.sqrt(np.maximum(guide[:, 11] - guide[:, 10] ** 2, 0))
                         / np.maximum(guide[:, 4], .04), 0, 1)
        gray = 1 - np.clip(np.ptp(rgb, axis=1) / (rgb.max(1) + .05), 0, 1)
        change = probe - old
        lifts = change @ np.array([.22897456, .69173852, .07928692]) > 0
        error = (old - x) - (t - n)
        rows.append((case['family'], error, p95(error), change, fine, region, gray, lifts))
    return rows


def fit(rows):
    weights = {'photo': .50, 'gray': .15, 'color': .15, 'cube': .20}
    families = np.array([row[0] for row in rows])
    if set(families) != set(weights):
        raise ValueError('Expected photographs, gray and color layouts, and the original color lattice')
    best = None
    for low, high in [(0, .1), (0, .2), (0, .4), (.025, .15), (.05, .15), (.05, .25), (.05, .45), (.1, .25)]:
        errors = {}
        for _, error, base, change, fine, region, gray, lifts in rows:
            detail = smooth((fine - low) / (high - low))
            shapes = {
                'detail': detail, 'texture': detail * region, 'gray': detail * gray,
                'positiveOnly': np.where(lifts, detail, 1), 'retained': np.where(lifts, detail, region),
                'regional': detail * (.4 + .6 * region),
            }
            for name, confidence in shapes.items():
                for gain in (.5, 1, 1.5):
                    estimate = error + change * (gain * confidence[:, None])
                    errors.setdefault((name, gain), []).append(p95(estimate) - base)
        for (name, gain), deltas in errors.items():
            d = np.array(deltas)
            score = sum(w * np.mean((d + 1.5 * np.maximum(d, 0))[families == family])
                        for family, w in weights.items())
            if best is None or score < best['score']:
                best = dict(detailStart=low, detailEnd=high, confidence=name, maximumShare=.35 * gain,
                            score=float(score), sources=len(rows))
    return best


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    print(json.dumps(fit(load(parser.parse_args().manifest)), indent=2, allow_nan=False))
