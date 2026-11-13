"""Build the global Saturation response from the two registered SDR color charts.

Supply the adjustments-001 and response-model-001 directories, an output binary,
and a JSON manifest. Use compress.swift to losslessly pack the binary for SwiftPM.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

import numpy as np
from scipy.interpolate import PchipInterpolator

from adaptive_data import FrozenSet


def build(coarse, fine):
    dimension = 32
    amounts = np.array([-100, -50, -25, -10, 0, 10, 25, 50, 100])
    luminance = np.array([0.2289746, 0.6917385, 0.0792869])
    diagonal = np.arange(dimension) * (1 + dimension + dimension ** 2)

    def nodes(dataset, suffix):
        chart = dataset.read('adjust-chart-' + suffix)
        if chart.shape != (256, 1024, 4):
            raise ValueError('Expected the full 32-cubed calibration chart')
        return chart[128::4, :, :3].reshape(-1, 3).astype(float)

    neutral = [nodes(dataset, 'neutral') for dataset in (coarse, fine)]
    values = []
    for amount in amounts:
        if amount == 0:
            values.append(np.zeros_like(neutral[0]))
            continue
        index = 0 if abs(amount) >= 50 else 1
        source = neutral[index]
        target = nodes((coarse, fine)[index], f'Saturation-{amount}')
        if amount == -100:
            # The slight disagreement among exported neutral RGB channels is ICC rounding.
            target = target.mean(axis=1, keepdims=True)
        values.append(target - source)
    values = np.stack(values)
    values[:, diagonal] = 0

    # Interpolate the measured channel motion monotonically in slider units.
    # Strip the analytic chroma term from values and derivatives before doing
    # *spatial* interpolation. This gives exact neutrals and a gray endpoint
    # even between the encoded-P3 lattice nodes.
    strengths = amounts / 100
    slopes = PchipInterpolator(strengths, values, axis=0).derivative()(strengths)
    chroma = neutral[0] - (neutral[0] @ luminance)[:, None]
    residual = values - strengths[:, None, None] * chroma
    slopes -= chroma
    residual[0] = residual[0].mean(axis=1, keepdims=True)
    residual[:, diagonal] = 0
    slopes[:, diagonal] = 0

    # CIImage bitmap rows start at the top. The Metal sampler's first row is
    # green=blue=0. Two adjacent cubes store the value and tangent of one knot.
    rows = dimension ** 2
    atlas = np.ones((rows, len(amounts) * 2 * dimension, 4), dtype='<f2')
    for i in range(len(amounts)):
        for offset, table in enumerate((residual[i], slopes[i])):
            column = (2 * i + offset) * dimension
            atlas[:, column:column + dimension, :3] = table.reshape(rows, dimension, 3)[::-1]
    if not np.isfinite(atlas).all():
        raise ValueError('Nonfinite saturation calibration')
    blob = b'BRSAT001' + struct.pack('<II', dimension, len(amounts)) + atlas.tobytes()
    manifest = dict(format='BRSAT001: dimension and knot count as little-endian UInt32, then RGBAh atlas',
                    amounts=amounts.tolist(), dimension=dimension,
                    interpolation='PCHIP by signed amount, tetrahedral by encoded Display-P3 color',
                    units='linear Display-P3 residual relative to linear luminance-based saturation',
                    references=[*coarse.evidence.values(), *fine.evidence.values()],
                    outputSHA256=hashlib.sha256(blob).hexdigest())
    return blob, manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('coarse', 'fine', 'output', 'manifest'):
        parser.add_argument(key, type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.manifest.exists():
        parser.error('Choose fresh output paths')
    blob, manifest = build(FrozenSet(args.coarse), FrozenSet(args.fine))
    args.output.write_bytes(blob)
    args.manifest.write_text(json.dumps(manifest, indent=2) + '\n')
    print(manifest['outputSHA256'], len(blob), 'bytes')
