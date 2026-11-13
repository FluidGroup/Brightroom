"""Fit the additional loss across the −50 to −100 Shadows interval on a registered 32³ lattice."""
import argparse
import json
from pathlib import Path

import numpy as np

from error_metrics import nearest_rank
from tone_chart import color_lattice, digest, registered_chart


def fit(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    sample = manifest_path.parent / manifest['sample']
    if digest(sample) != manifest['sha256'] or manifest['delta'] != .125:
        raise ValueError('Changed public calibration samples or probe strength')
    with np.load(sample, allow_pickle=False) as captures:
        expected = np.arange(256 * 1024).reshape(256, 1024)[128::4].ravel()
        if not np.array_equal(captures['indices'], expected):
            raise ValueError('Expected the first row of each four-row color strip')
        source, half, full, less, more = [captures[k].astype(float) for k in ('source', 'half', 'full', 'less', 'more')]
    if any(a.shape != (32768, 3) or not np.isfinite(a).all() for a in (source, half, full, less, more)):
        raise ValueError('Expected all 32³ opaque linear RGB samples for each public setting')

    targets = {}
    for amount in (0, -50, -100):
        pixels, proof = registered_chart(Path(manifest['registration']), 'adjust-chart-', 'Shadows2012', amount)
        if (proof['source'] != manifest['source'] or proof['profile'] != manifest['icc']
                or proof['reference']['referenceSHA256'] != manifest['reference'][str(amount)]):
            raise ValueError(f'Unpaired Shadows {amount} reference')
        targets[amount] = color_lattice(pixels)
    error = (targets[-100] - targets[0]) - (full - source)
    interval_error = (targets[-100] - targets[-50]) - (full - half)
    derivative = (more - less) / (2 * manifest['delta'])
    size = np.abs(error).max(axis=1)
    weight = .5 + 1.5 * (size >= .7 * nearest_rank(size, .95))
    information = np.sum(weight * (derivative * derivative).sum(axis=1))
    if information <= 0:
        raise ValueError('The two Metal probes produced no change')
    cross = np.sum(weight * (derivative * (.5 * (error + interval_error))).sum(axis=1))
    return dict(colors=len(weight), gain=float(cross / (1.025 * information)),
                source=manifest['source'], baselineKernel=manifest['baseline'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path, help='source, ICC, reference hashes and the signed native probes')
    print(json.dumps(fit(parser.parse_args().manifest), indent=2, allow_nan=False))
