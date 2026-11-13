"""Reproduce the negative Highlights/Shadows color coefficients from paired Lightroom renders."""
import argparse
import hashlib
import json
from pathlib import Path
import re

import numpy as np

from adaptive_data import FrozenSet


def normal_equations(neutral, adjusted, adobe_neutral, adobe_adjusted, control, floor):
    """Fit RGB distance from gray to the difference in the two renderers' signed responses."""
    weights = np.array([0.22897456, 0.69173852, 0.07928692], dtype=np.float32)
    input_y = neutral @ weights
    output_y = adjusted @ weights
    input_color = neutral - input_y[:, None]
    target = neutral + (adobe_adjusted - adobe_neutral)
    residual = adjusted - output_y[:, None] - (target - (target @ weights)[:, None])
    change = input_color * ((output_y - input_y) / np.maximum(input_y + floor, 1e-5))[:, None]

    def encode(linear):
        linear = np.clip(linear, 0, 1)
        return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055)

    code_y = encode(input_y)
    code = encode(neutral)
    knots = np.maximum(1 - 4 * abs(code_y[:, None] - np.linspace(0, 1, 5)), 0)
    if control == 'Highlights2012':
        components = np.column_stack((np.ones(len(code)), np.ptp(code, axis=1)))
    else:
        components = np.column_stack((np.ones(len(code)), code[:, 0] - code_y, code[:, 2] - code_y))
    basis = (components[:, :, None] * knots[:, None, :]).reshape(len(code), -1)
    power = np.sum(change ** 2, axis=1)
    # Give each scene its own normalization so a single saturated chart cannot dominate the fit.
    weight = 1 / max(power.mean(), 0.000002) / len(code)
    return basis.T @ (basis * (power * weight)[:, None]), -basis.T @ (np.sum(residual * change, axis=1) * weight)


def verify_measurements(model, decoded, directories):
    """Recompute sufficient statistics using the registered TIFFs and the pre-correction public output."""
    sets = {path.name: FrozenSet(path) for path in directories}
    cases = {name: {row['id']: row for row in json.loads((data.root / 'cases.json').read_text())['cases']}
             for name, data in sets.items()}
    public = {Path(row['input']).stem: row for row in json.loads((decoded / 'manifest.json').read_text())}
    totals = {control: [] for control in model['controls']}
    for scene in model['scenes']:
        source_hash = scene['inputSHA256']
        name = scene['acquisition']

        def pair(control):
            evidence = scene[control]
            identity = evidence['id']
            case = cases[name][identity]
            parameters = {} if control == 'neutral' else {control: -50}
            if case['inputSHA256'] != source_hash or case['parameters'] != parameters:
                raise ValueError(f'Unexpected input or Lightroom setting for {identity}')
            reference = sets[name].read(identity)
            if sets[name].evidence[identity]['referenceSHA256'] != evidence['referenceSHA256']:
                raise ValueError(f'Unexpected Lightroom reference for {identity}')
            record = public[scene['publicNeutralID'] if control == 'neutral' else identity]
            pixels = (decoded / record['output']).read_bytes()
            if (record['sha256'] != evidence['brightroomSHA256']
                    or hashlib.sha256(pixels).hexdigest() != evidence['brightroomDecodedSHA256']
                    or record['space'] != 'extended-linear Display-P3 D65'):
                raise ValueError(f'Unexpected Brightroom baseline or working space for {identity}')
            bitmap = np.frombuffer(pixels, '<f4').reshape(record['height'], record['width'], 4)
            if bitmap.shape != reference.shape:
                raise ValueError(f'Different image extents for {identity}')
            return bitmap.reshape(-1, 4), reference.reshape(-1, 4)

        neutral, adobe_neutral = pair('neutral')
        rng = np.random.default_rng(int(source_hash[:8], 16))
        indices = rng.choice(len(neutral), min(model['samplesPerScene'], len(neutral)), replace=False)
        for control in totals:
            adjusted, adobe_adjusted = pair(control)
            sampled = [value[indices, :3].astype(np.float64)
                       for value in (neutral, adjusted, adobe_neutral, adobe_adjusted)]
            totals[control].append(normal_equations(*sampled, control, model['luminanceFloor']))

    for control, scenes in totals.items():
        matrix = np.sum([sample[0] for sample in scenes], axis=0)
        rhs = np.sum([sample[1] for sample in scenes], axis=0)
        np.testing.assert_allclose(matrix, model['controls'][control]['normalMatrix'], atol=1e-10)
        np.testing.assert_allclose(rhs, model['controls'][control]['rightHandSide'], atol=1e-10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', type=Path, help='verify the coefficients compiled into this Metal source')
    parser.add_argument('--public-decoded', type=Path, help='directory from decode.swift for the frozen public baseline')
    parser.add_argument('--reference-set', type=Path, action='append', default=[], help='registered Lightroom acquisition')
    args = parser.parse_args()
    if bool(args.public_decoded) != bool(args.reference_set):
        parser.error('Supply --public-decoded and the matching --reference-set directories together')
    model = json.loads(Path(__file__).with_name('negative-tone-color-calibration.json').read_text())
    if args.public_decoded:
        verify_measurements(model, args.public_decoded, args.reference_set)
    source = args.check.read_text() if args.check else None
    for control, data in model['controls'].items():
        matrix = np.asarray(data['normalMatrix'])
        diagonal = np.diag(matrix)
        penalty = data['ridge'] * np.maximum(diagonal, diagonal.max() * 0.01) + 1e-9
        rows = np.linalg.solve(matrix + np.diag(penalty), data['rightHandSide']).reshape(-1, 5).T
        symbol = 'highlightColor' if control == 'Highlights2012' else 'shadowColor'
        if source is None:
            print(symbol)
            for row in rows:
                print(f'  float{len(row)}(' + ', '.join(f'{v:.9f}f' for v in row) + '),')
        else:
            block = re.search(rf'\b{symbol}\[5\] = \{{([^}}]+)\}};', source)
            if block is None:
                raise ValueError(f'Missing Metal coefficients for {symbol}')
            values = re.findall(r'(-?\d+\.\d+)f', block[1])
            np.testing.assert_array_equal(np.array(values, dtype=np.float32), rows.flatten().astype(np.float32))
            print(f'{symbol}: {rows.size} compiled coefficients match')


if __name__ == '__main__':
    main()
