"""Recover the positive Shadows chroma correction from the pre-correction public output and registered +50 pairs."""
import argparse
import hashlib
import json
from pathlib import Path
import re

import numpy as np

from adaptive_data import FrozenSet


def sha(file):
    with file.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def public(folder, identity):
    rows = json.loads((folder / 'manifest.json').read_text())
    row = next(r for r in rows if Path(r['input']).stem == identity)
    if row['space'] != 'extended-linear Display-P3 D65' or sha(Path(row['input'])) != row['sha256']:
        raise ValueError(f'Unregistered public output for {identity}')
    data = np.fromfile(folder / row['output'], '<f4').reshape(row['height'], row['width'], 4)
    if not np.isfinite(data).all() or np.max(abs(data[..., 3] - 1)) >= 1e-6:
        raise ValueError(f'Invalid public pixels for {identity}')
    return data[..., :3]


def normal_equations(neutral, adjusted, reference_neutral, reference_adjusted):
    """Each chart contributes its chroma error and three measures of its public +50 response."""
    if not neutral.shape == adjusted.shape == reference_neutral.shape == reference_adjusted.shape:
        raise ValueError('Mismatched calibration image dimensions')
    count = neutral.size // 3
    sample = np.linspace(0, count - 1, min(30000, count), dtype=int)
    x, y, z, target = [v.reshape(-1, 3)[sample].astype(float)
                      for v in (neutral, adjusted, reference_neutral, reference_adjusted)]
    luminance = np.array([0.2289746, 0.6917385, 0.0792869])
    level = x @ luminance
    chroma = x - level[:, None]
    lift = y - x
    residual = (target - z) - lift
    residual -= (residual @ luminance)[:, None]
    span = np.ptp(x, axis=1)
    features = np.column_stack(((lift @ luminance) / (level + 0.01),
                                (np.ptp(y, axis=1) - span) / np.maximum(span, 1e-5),
                                np.maximum(lift, 0).max(axis=1) / (x.max(axis=1) + 0.01)))
    weight = 1 / ((1e-6 + np.mean(residual ** 2)) * len(x))
    matrix = (features.T * (np.sum(chroma ** 2, axis=1) * weight)) @ features
    target = features.T @ (np.sum(residual * chroma, axis=1) * weight)
    return matrix, target


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('chart', 'chart_public_neutral', 'chart_public_adjusted', 'layouts', 'layouts_public'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--check', type=Path, help='verify the coefficients compiled into HighlightShadowKernels.metal')
    args = parser.parse_args()
    cube = FrozenSet(args.chart)
    layouts = FrozenSet(args.layouts)
    # Only the lower chart half is the RGB lattice. The upper half contains other probes.
    arrays = [public(args.chart_public_neutral, 'brightroom'), public(args.chart_public_adjusted, 'brightroom'),
              cube.read('adjust-chart-neutral')[..., :3], cube.read('adjust-chart-Shadows2012-50')[..., :3]]
    equations = [normal_equations(*(chart[128::4] for chart in arrays))]
    cases = json.loads((args.layouts / 'cases.json').read_text())['cases']
    selected = [row for row in cases if row.get('split') == 'calibration' and row['parameters'] == {'Shadows2012': 50}]
    if len(selected) != 4:
        raise ValueError('Expected four registered color-layout calibrations')
    for row in selected:
        neutral = next(c for c in cases if c['parameters'] == {} and c['inputSHA256'] == row['inputSHA256'])
        n, a = neutral['id'], row['id']
        equations.append(normal_equations(public(args.layouts_public, n), public(args.layouts_public, a),
                                          layouts.read(n)[..., :3], layouts.read(a)[..., :3]))
    matrix = sum(a for a, _ in equations)
    rhs = sum(b for _, b in equations)
    diagonal = np.diag(matrix)
    penalty = 0.2 * np.maximum(diagonal, 0.01 * diagonal.max()) + 1e-7
    weights = np.linalg.solve(matrix + np.diag(penalty), rhs)
    if args.check:
        source = args.check.read_text().split('static float2 positiveShadowBounds(', 1)[1]
        value = re.search(r'const float3 coefficients = float3\(([^)]+)\);', source)[1]
        compiled = [float(number.strip().removesuffix('f')) for number in value.split(',')]
        np.testing.assert_allclose(compiled, weights, rtol=0, atol=5.1e-8)
        print('Verified three positive Shadows chroma coefficients')
    else:
        print(', '.join(f'{value:.7f}f' for value in weights))
