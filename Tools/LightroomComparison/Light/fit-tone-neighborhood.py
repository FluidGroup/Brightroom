"""Rebuild the negative tone neighborhood coefficients from paired, ICC-decoded public and Adobe outputs."""
import argparse
import hashlib
import json
from pathlib import Path
import re

import numpy as np
from scipy.ndimage import gaussian_filter, map_coordinates

from adaptive_data import FrozenSet


def read(path):
    return json.loads(path.read_text())


def encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def normal_equations(neutral, adjusted, adobe_neutral, adobe_adjusted, source_hash, highlights):
    """Fit an additive encoded change at -50 to the observed difference between the two adjustments."""
    weights = np.array([.22897456, .69173852, .07928692], dtype=np.float32)
    height, width = neutral.shape[:2]
    scale = min(1, 256 / max(height, width))
    shape = np.maximum(1, np.ceil(np.array([height, width]) * scale).astype(int))
    fy, fx = shape / [height, width]
    log_y = np.log(np.maximum(np.clip(neutral, 0, 1) @ weights, .0001)) / 9.3 + 1
    softened = gaussian_filter(log_y, max(0, (1 / scale - 1) / 2), mode='nearest')
    yy, xx = np.meshgrid((np.arange(shape[0]) + .5) / fy - .5,
                         (np.arange(shape[1]) + .5) / fx - .5, indexing='ij')
    guide = map_coordinates(softened, [yy, xx], order=1, mode='nearest')

    indices = np.random.default_rng(int(source_hash[:8], 16)).choice(
        height * width, min(10000, height * width), replace=False)
    positions = np.array([(axis + .5) * factor - .5
                          for axis, factor in zip(np.unravel_index(indices, (height, width)), (fy, fx))])
    pixel = log_y.ravel()[indices]
    mean = guide.mean(dtype='f8')
    if highlights:
        levels = [pixel]
        for radius in [4, 16, 64, 256]:
            blurred = gaussian_filter(guide, radius * max(shape) / 1024, mode='nearest')
            levels.append(map_coordinates(blurred, positions, order=1, mode='nearest'))
        levels.append(np.full(len(pixel), mean))
        terms = np.diff(np.column_stack(levels), axis=1)
    else:
        terms = (pixel - mean)[:, None]

    def sample(image):
        return image.reshape(-1, 3)[indices].astype('f8')

    source, end = sample(neutral), sample(adjusted)
    residual = end - (sample(adobe_adjusted) - sample(adobe_neutral) + source)
    code = encode(source @ weights)
    hats = np.maximum(1 - 4 * abs(code[:, None] - np.linspace(0, 1, 5)), 0)
    basis = (terms[:, :, None] * hats[:, None, :]).reshape(len(code), -1)
    basis *= min(1, guide.std(dtype='f8') / .015)
    derivative = np.where(end < .0031308, 1 / 12.92, 2.4 / 1.055 * np.maximum(end, 0) ** (1 - 1 / 2.4))
    error = abs(residual).max(axis=1)
    importance = (1 + np.minimum(error / max(.005, np.quantile(error, .8)), 3))
    importance /= max(.012, np.quantile(error, .95, method='inverted_cdf')) * len(error)
    return (basis.T @ (basis * (importance * (derivative * derivative).sum(axis=1))[:, None]),
            -basis.T @ (importance * (derivative * residual).sum(axis=1)))


def public_images(folder):
    """Bind a decoded array to its source PNG and the declared working space."""
    index = {Path(row['input']).stem: row for row in read(folder / 'manifest.json')}

    def image(name):
        row = index[name]
        with Path(row['input']).open('rb') as source:
            if hashlib.file_digest(source, 'sha256').hexdigest() != row['sha256']:
                raise ValueError(f'Changed public output for {name}')
        if row['space'] != 'extended-linear Display-P3 D65':
            raise ValueError(f'Unexpected decoded color space for {name}')
        data = np.fromfile(folder / row['output'], dtype='<f4').reshape(row['height'], row['width'], 4)
        if not np.isfinite(data).all() or np.max(abs(data[..., 3] - 1)) >= 1e-6:
            raise ValueError(f'Unexpected decoded public pixels for {name}')
        return data[..., :3]

    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path, help='signed sample manifest with both registrations and public output IDs')
    parser.add_argument('neutral_decoded', type=Path)
    parser.add_argument('adjusted_decoded', type=Path)
    parser.add_argument('--check', type=Path, help='compare the fitted float values with the compiled Metal arrays')
    args = parser.parse_args()
    neutral, adjusted = public_images(args.neutral_decoded), public_images(args.adjusted_decoded)
    training = {r['sourceSHA256'] for r in read(Path(__file__).with_name('highlights-strength-calibration.json'))['samples']}
    acquisitions = {}
    manifest = read(args.cases)

    def adobe(path, case_id, source_hash, parameters, reference_hash):
        if path not in acquisitions:
            root = Path(path)
            cases = {r['id']: r for r in read(root / 'cases.json')['cases']}
            acquisitions[path] = FrozenSet(root), cases
        frozen, cases = acquisitions[path]
        case = cases[case_id]
        if (case['inputSHA256'] != source_hash or case['parameters'] != parameters
                or frozen.references[case_id]['referenceSHA256'] != reference_hash):
            raise ValueError(f'Unexpected Lightroom input, adjustment or export for {case_id}')
        return frozen.read(case_id)[..., :3]

    output = {}
    for control in ['Highlights2012', 'Shadows2012']:
        scenes = [r for r in manifest if r['source'] in training and r['amount'] == -50 and r['control'] == control]
        if len(scenes) != len(training) or {r['source'] for r in scenes} != training:
            raise ValueError(f'Expected one {control} calibration pair per source')
        totals = []
        for scene in scenes:
            source_hash = scene['source']
            first = adobe(scene['neutralRoot'], scene['neutralID'], source_hash, {}, scene['neutralReferenceSHA256'])
            last = adobe(scene['root'], scene['id'], source_hash, {control: -50}, scene['referenceSHA256'])
            src, end = neutral(scene['neutralPublic']), adjusted(scene['id'])
            if not first.shape == last.shape == src.shape == end.shape:
                raise ValueError(f'Image extents differ for {scene["id"]}')
            totals.append(normal_equations(src, end, first, last, source_hash, control == 'Highlights2012'))
        matrix = np.sum([a for a, _ in totals], axis=0)
        rhs = np.sum([b for _, b in totals], axis=0)
        diagonal = np.diag(matrix)
        penalty = 3 * np.maximum(diagonal, diagonal.max() * .015) + 1e-8
        rows = np.linalg.solve(matrix + np.diag(penalty), rhs).reshape(-1, 5).T
        if control == 'Highlights2012':
            output['local'], output['outer'] = rows[:, :4], rows[:, 4]
        else:
            output['shadow'] = rows.flatten()

    source = args.check.read_text() if args.check else None
    for name, values in output.items():
        if source is None:
            print(name, np.array2string(values, precision=7))
        else:
            block = re.search(rf'\b{name}\[5\] = \{{([^}}]+)\}};', source)
            if block is None:
                raise ValueError(f'Missing Metal coefficients for {name}')
            actual = np.array(re.findall(r'(-?\d+\.\d+)f', block[1]), dtype=float)
            np.testing.assert_allclose(actual, values.flatten(), atol=5.1e-8, rtol=0)
            print(f'{name} matches {values.size} coefficients at seven decimal places')


if __name__ == '__main__':
    main()
