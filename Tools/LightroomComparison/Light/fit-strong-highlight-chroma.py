"""Fit the relative RGB loss for strong negative Light on the registered 32³ color lattice."""
import argparse
import json
from pathlib import Path
import re

import numpy as np

from tone_chart import color_lattice, public_chart, registered_chart


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path, help='registration containing neutral and both calibration strengths')
    parser.add_argument('samples', type=Path, help='input, amount and output profile for the public baseline renders')
    parser.add_argument('decoded', type=Path, help='those renders decoded with Light/decode.swift')
    parser.add_argument('metrics', type=Path, help='pre-correction whole-chart gamut measurements')
    parser.add_argument('--control', choices=['Highlights2012', 'Shadows2012'], default='Highlights2012')
    parser.add_argument('--check', type=Path, help='verify the coefficients in HighlightShadowKernels.metal')
    args = parser.parse_args()
    samples = {r['id']: r for r in json.loads(args.samples.read_text())}
    decoded = {Path(r['input']).stem: r for r in json.loads((args.decoded / 'manifest.json').read_text())}
    control = args.control
    measured = {r['id']: r for r in json.loads(args.metrics.read_text())['rows'] if r['control'] == control}

    neutral, _ = registered_chart(args.registration, 'adjust-chart-', control, 0)
    source = color_lattice(neutral).clip(0, 1)
    prediction, adobe = [], []
    # Reserve the −100 Shadows export for validation of the weaker interval's color response.
    amounts = [-50, -100] if control == 'Highlights2012' else [-10, -25]
    for amount in amounts:
        key = f'adjust-chart-{control}-{amount}'
        short = f'{control}-{abs(amount)}'
        target, evidence = registered_chart(args.registration, 'adjust-chart-', control, amount)
        pixels = public_chart(samples[short], decoded[short], args.decoded, measured[key],
                              control, amount, target, evidence)
        prediction.append(color_lattice(pixels))
        adobe.append(color_lattice(target))

    loss = prediction[0] - prediction[1]
    error = (adobe[0] - adobe[1]) - loss
    chroma_error = error - (error @ [.22897456, .69173852, .07928692])[:, None]
    peak = source.max(axis=1, keepdims=True)
    span = np.ptp(source, axis=1, keepdims=True)
    direction = (source / np.maximum(peak, 1e-8) if control == 'Highlights2012'
                 else (source - source.min(axis=1, keepdims=True)) / (span + .04))
    weight = span / (peak + .05) * direction
    weighted_loss = weight * loss
    coefficients = (weighted_loss * chroma_error).sum(axis=0) / (weighted_loss ** 2).sum(axis=0)
    if args.check:
        name = 'strongChroma' if control == 'Highlights2012' else 'strongShadowChroma'
        match = re.search(rf'\b{name} = float3\(([^)]+)\)', args.check.read_text())
        if not match:
            raise ValueError(f'Missing coefficients for {control}')
        np.testing.assert_allclose([float(x.strip().removesuffix('f')) for x in match[1].split(',')],
                                   coefficients, rtol=0, atol=2e-6)
    print(json.dumps({'codes': len(source), 'coefficients': coefficients.tolist()}))


if __name__ == '__main__':
    main()
