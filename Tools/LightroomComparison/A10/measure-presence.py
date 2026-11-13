"""Measure individual registered Presence edits on one source and their optional combination.

All measurements use fresh 16-bit TIFF decodes in extended-linear Display P3.
The measured luminance and color-span projections describe the reference itself.
They are diagnostic lower bounds, not predictions of an editing feature.
"""
import argparse
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

import numpy as np

from presence_reference import CONTROLS, changes, registered

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Light'))
from error_metrics import nearest_rank
from paired_light import decode

LUMINANCE = np.array([.22897456, .69173852, .07928692])


def measure(images, differences):
    """Accumulate nearest-rank RGB errors across every pixel with bounded RGB working storage."""
    height, width = images[0].shape[:2]
    if any(rgb.shape != (height, width, 3) for rgb in images):
        raise ValueError('Decoded dimensions do not match')
    summaries = {}
    rows_per_chunk = max(1, 262144 // width)
    for start in range(0, height, rows_per_chunk):
        end = min(start + rows_per_chunk, height)
        block = [rgb[start:end].reshape(-1, 3).astype(np.float64) for rgb in images]
        for name, delta in differences(block):
            if name not in summaries:
                summaries[name] = [np.empty(width * height, np.float32), 0.0]
            maxima, squares = summaries[name]
            maxima[start * width:end * width] = np.abs(delta).max(axis=1)
            summaries[name][1] = squares + float(np.sum(delta * delta))
    return {name: dict(pixels=maxima.size, p95MaxChannel=nearest_rank(maxima, .95),
                       rgbRMS=float(np.sqrt(squares / (3 * maxima.size))))
            for name, (maxima, squares) in summaries.items()}


def color_components(block):
    neutral, edited = block
    change = edited - neutral
    yield 'editMinusNeutral', change
    chromatic_change = change - (change @ LUMINANCE)[:, None]
    yield 'residualWithMeasuredLuminance', chromatic_change
    # Subtract the projection along the original RGB hue line; neutral pixels have no such axis.
    span = neutral - (neutral @ LUMINANCE)[:, None]
    length_squared = np.einsum('ij,ij->i', span, span)
    dot = np.einsum('ij,ij->i', chromatic_change, span)
    scale = np.divide(dot, length_squared, out=np.zeros_like(dot), where=length_squared > 1e-12)
    yield 'residualWithMeasuredLuminanceAndSpan', chromatic_change - scale[:, None] * span


def interactions(block):
    neutral, joint, *singles = block
    combined = joint - neutral
    yield 'jointMinusNeutral', combined
    summed = sum((single - neutral for single in singles), start=np.zeros_like(neutral))
    yield 'jointMinusSumOfIsolatedEdits', combined - summed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registration', type=Path)
    parser.add_argument('neutral', help='registered neutral ID')
    parser.add_argument('single', nargs='+', help='one registered isolated edit ID per control')
    parser.add_argument('--joint', help='registered edit with all the same controls and strengths')
    parser.add_argument('--decoder', required=True, type=Path, help='compiled Light/decode.swift')
    parser.add_argument('--output', required=True, type=Path, help='new JSON measurement file')
    args = parser.parse_args()
    root = args.registration.resolve()
    cases = json.loads((root / 'cases.json').read_text())['cases']
    refs = json.loads((root / 'references.json').read_text())['references']

    def index(rows):
        indexed = {row['id']: row for row in rows}
        if len(indexed) != len(rows):
            raise ValueError('Duplicate registered case IDs')
        return indexed

    cases, refs = index(cases), index(refs)
    neutral = registered(root, cases, refs, args.neutral)
    if (neutral['group'] != 'neutral' or neutral['declared']
            or any(float(neutral['applied'][k]) != 0 for k in CONTROLS)):
        raise ValueError('Expected a registered neutral with all three Presence controls at zero')
    singles = []
    active = {}
    for name in args.single:
        record = registered(root, cases, refs, name)
        strengths = changes(neutral, record)
        if len(strengths) != 1 or active.keys() & strengths.keys():
            raise ValueError(f'Expected one distinct isolated control for {name}')
        active.update(strengths)
        singles.append(record)
    joint = registered(root, cases, refs, args.joint) if args.joint else None
    if joint and (len(singles) < 2 or changes(neutral, joint) != active):
        raise ValueError('Joint edit must contain exactly the measured controls at the same strengths')
    report = dict(neutral=neutral['proof'], space='extended-linear Display-P3 D65', isolated={})
    with TemporaryDirectory() as tmp:
        directory = Path(tmp)
        decoder = args.decoder.resolve()
        zero = decode(neutral['path'], decoder, directory / 'neutral')
        decoded = []
        for i, record in enumerate(singles):
            rgb = decode(record['path'], decoder, directory / str(i))
            decoded.append(rgb)
            control, = record['declared']
            report['isolated'][control] = dict(proof=record['proof'], amount=active[control],
                                               **measure([zero, rgb], color_components))
        if joint:
            combined = decode(joint['path'], decoder, directory / 'joint')
            report['joint'] = dict(proof=joint['proof'], controls=active,
                                   **measure([zero, combined, *decoded], interactions))
    with args.output.open('x') as stream:
        stream.write(json.dumps(report, indent=2, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
