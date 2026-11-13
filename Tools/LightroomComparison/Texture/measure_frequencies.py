"""Measure the signed contrast change of known spatial frequencies in isolated Texture exports."""
import argparse
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

import numpy as np

TOOLS = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(TOOLS / 'Light'), str(TOOLS / 'A10')]
from error_metrics import rgb_error
from paired_light import decode
from presence_reference import CONTROLS, changes, registered

SIDE = 96
PERIODS = (2, 4, 8, 12, 16, 24, 32, 48)
TONES = ((.25, .06), (.5, .035), (.5, .18), (.75, .06))
LUMINANCE = np.array([.22897457, .69173855, .07928692])


def encoded_luminance(image):
    linear = image @ LUMINANCE
    return np.where(linear < .0031308, 12.92 * linear, 1.055 * np.maximum(0, linear) ** (1 / 2.4) - .055)


def location(row, column):
    # The interior spans 48 columns, an integer number of periods for every patch.
    return (slice(row * SIDE + 24, row * SIDE + 72), slice(column * SIDE + 24, column * SIDE + 72))


def harmonics(patch, period):
    """Project the patch onto the generated cosine and its quadrature in encoded Display P3."""
    phase = 2 * np.pi * np.arange(24, 72) / period
    columns = [np.ones_like(phase), np.cos(phase)]
    # A two-pixel cosine alternates between its extrema; the sine is identically zero.
    if period != 2:
        columns.append(np.sin(phase))
    design = np.column_stack(columns)
    coef = np.linalg.lstsq(design, patch.mean(axis=0), rcond=None)[0]
    return dict(mean=float(coef[0]), cosine=float(coef[1]), sine=float(coef[2]) if period != 2 else 0.0,
                rmsOffFundamental=float(np.sqrt(np.mean((patch - design @ coef) ** 2))))


def verify_input(source):
    """Check actual source pixels against every displayed patch, including the second repetition."""
    height, width, _ = source.shape
    if height != SIDE * len(TONES) or width not in (SIDE * len(PERIODS), 2 * SIDE * len(PERIODS)):
        raise ValueError('Expected the unscaled chart produced by frequency-chart.swift')
    value = encoded_luminance(source)
    if np.max(np.ptp(source, axis=2)) > .001:
        raise ValueError('Expected neutral gray patches')
    for row, (mean, amplitude) in enumerate(TONES):
        for column in range(width // SIDE):
            period = PERIODS[column % len(PERIODS)]
            expected = mean + amplitude * np.cos(2 * np.pi * np.arange(SIDE) / period)
            block = value[row * SIDE:(row + 1) * SIDE, column * SIDE:(column + 1) * SIDE]
            if np.max(np.abs(block - expected)) > .001:
                raise ValueError(f'Unexpected source waveform in row {row}, column {column}')


def measure(neutral, edit):
    zero, changed = (encoded_luminance(image) for image in (neutral, edit))
    result = []
    for row, (mean, amplitude) in enumerate(TONES):
        for column in range(neutral.shape[1] // SIDE):
            period = PERIODS[column % len(PERIODS)]
            selection = location(row, column)
            a, b = (harmonics(channel[selection], period) for channel in (zero, changed))
            if a['cosine'] <= 0:
                raise ValueError('The registered neutral has lost or reversed the source contrast')
            result.append(dict(row=row, column=column, period=period, level=mean, amplitude=amplitude,
                               relativeContrastChange=b['cosine'] / a['cosine'] - 1,
                               meanShift=b['mean'] - a['mean'], neutral=a, edited=b))
    return dict(tiles=result, signal=rgb_error(edit, neutral))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path)
    parser.add_argument('neutral', help='registered neutral case ID')
    parser.add_argument('edits', nargs='+', help='registered cases isolating Texture on the same chart')
    parser.add_argument('--decoder', required=True, type=Path, help='compiled Light/decode.swift')
    parser.add_argument('--output', required=True, type=Path, help='new JSON report')
    args = parser.parse_args()
    root = args.registration.resolve()
    cases = {c['id']: c for c in json.loads((root / 'cases.json').read_text())['cases']}
    refs = {c['id']: c for c in json.loads((root / 'references.json').read_text())['references']}
    control = registered(root, cases, refs, args.neutral)
    if (control['group'] != 'neutral' or control['declared'] or control['proof']['processVersion'] != '15.4'
            or any(float(control['applied'][key]) != 0 for key in CONTROLS)):
        raise ValueError('Expected an unadjusted Process Version 15.4 control')
    report = dict(control=control['proof'], transfer='Display P3 encoded luminance after ICC conversion', edits={})
    with TemporaryDirectory() as temp:
        directory = Path(temp)
        decoder = args.decoder.resolve()
        verify_input(decode(Path(cases[args.neutral]['input']), decoder, directory / 'source'))
        neutral = decode(control['path'], decoder, directory / 'neutral')
        for i, identity in enumerate(args.edits):
            ref = registered(root, cases, refs, identity)
            parameters = changes(control, ref)
            if parameters.keys() != {'Texture'} or identity in report['edits']:
                raise ValueError(f'Expected one distinct Texture case for {identity}')
            edit = decode(ref['path'], decoder, directory / str(i))
            report['edits'][identity] = dict(amount=parameters['Texture'], proof=ref['proof'], **measure(neutral, edit))
    with args.output.open('x') as stream:
        stream.write(json.dumps(report, indent=2, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
