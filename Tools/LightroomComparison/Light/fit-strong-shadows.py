"""Recover the strong Shadows strength coordinate and hue response from neutral through −50."""
import argparse
import json
from pathlib import Path
import re

import numpy as np
from shadow_interval import extrema, fit_range

from tone_chart import color_lattice, public_chart, registered_chart


CONTROL = 'Shadows2012'


def fit_hue(source, weak, medium, target):
    """Fit extra loss at the two source extrema using three luminances and six hue directions."""
    source = np.clip(source, 0, 1)
    peak = source.max(axis=1)
    span = np.ptp(source, axis=1)
    hue = (source - source.min(axis=1, keepdims=True)) / (span[:, None] + .025)
    other1, other2 = np.roll(hue, -1, axis=1), np.roll(hue, -2, axis=1)
    directions = np.column_stack((np.maximum(hue - np.maximum(other1, other2), 0),
                                  np.minimum(other1, other2)))
    y = source @ [.22897456, .69173852, .07928692]
    code = np.where(y <= .0031308, y * 12.92, 1.055 * y ** (1 / 2.4) - .055)
    knots = np.maximum(1 - abs(code[:, None] * 2 - np.arange(3)), 0)
    basis = (knots[:, :, None] * directions[:, None, :]).reshape(len(source), 18)
    basis *= (span / (peak + .05))[:, None]
    loss = extrema(weak - medium, source)
    residual = extrema(weak - target, source) - loss
    coefficients = []
    for index in (0, 1):
        design = basis * loss[:, index:index + 1]
        coefficients.append(np.linalg.solve(design.T @ design + .01 * np.eye(18), design.T @ residual[:, index]))
    return np.stack(coefficients, axis=1).reshape(3, 6, 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('research', type=Path, help='directory containing both ramp and both lattice acquisitions')
    parser.add_argument('samples', type=Path, help='signed public render requests for the color lattice')
    parser.add_argument('decoded', type=Path, help='public 16-bit renders decoded with Light/decode.swift')
    parser.add_argument('metrics', type=Path, help='whole-chart scores for the verified public baseline')
    parser.add_argument('--check', type=Path, help='compare both bounds and all 36 coefficients to Metal')
    args = parser.parse_args()
    samples = {r['id']: r for r in json.loads(args.samples.read_text())}
    records = {Path(r['input']).stem: r for r in json.loads((args.decoded / 'manifest.json').read_text())}
    metrics = {r['id']: r for r in json.loads(args.metrics.read_text())['rows'] if r['control'] == CONTROL}
    sources = {}
    charts, public, evidence = [], {}, []
    for chart in ('lattice', 'ramp'):
        levels = {}
        for amount in (0, -10, -25, -50):
            weak = amount in (-10, -25)
            if chart == 'lattice':
                prefix = 'adjust-chart-'
                root = 'response-model-001' if weak else 'adjustments-001'
            else:
                prefix = 'adaptcal-ramp-' if weak else 'adaptive-ramp-'
                root = 'adaptive-calibration-001' if weak else 'adaptive-002'
            image, proof = registered_chart(args.research / root, prefix, CONTROL, amount)
            identity = (proof['source'], proof['profile'])
            if identity != sources.setdefault(chart, identity):
                raise ValueError(f'Unpaired {chart} source or output ICC at {amount}')
            evidence.append(proof)
            if chart == 'lattice':
                levels[amount] = color_lattice(image)
                if amount in (0, -10, -25):
                    short = f'{CONTROL}-{abs(amount)}'
                    pixels = public_chart(samples[short], records[short], args.decoded, metrics[proof['id']],
                                          CONTROL, amount, image, proof)
                    public[amount] = color_lattice(pixels)
                    proof['publicPNG'] = records[short]['sha256']
            else:
                levels[amount] = image[::64, ::2, :3].reshape(-1, 3).astype('f8')
        charts.append(levels)

    black, white = fit_range(charts, (-10, -25, -50))
    gain = fit_hue(public[0], public[-10], public[-25], charts[0][-25])
    # Metal stores two triplets (primary and secondary) for the low extremum, followed by the high extremum.
    rows = gain.transpose(0, 2, 1).reshape(12, 3)
    if args.check:
        metal = args.check.read_text()
        bounds = [float(re.search(rf'constant float {name} = ([.\d]+)f;', metal)[1])
                  for name in ('shadowBlackRoom', 'shadowWhiteLimit')]
        table = metal.split('strongShadowHueGain[3][4] = {', 1)[1].split('};', 1)[0]
        stored = [[float(v.strip().removesuffix('f')) for v in row.split(',')]
                  for row in re.findall(r'float3\(([^)]+)\)', table)]
        np.testing.assert_allclose(bounds, [black, 1 + white], rtol=0, atol=1e-6)
        np.testing.assert_allclose(stored, rows, rtol=0, atol=2e-6)
    print(json.dumps(dict(blackRoom=black, whiteLimit=1 + white, hueGains=rows.tolist(), evidence=evidence),
                     indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
