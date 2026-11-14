"""Choose the source-color bandwidth for the negative Light neighborhood on frozen −50 exports."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from adaptive_data import FrozenSet
from error_metrics import nearest_rank
from tone_chart import digest


def read(path):
    return json.loads(path.read_text())


def p95(difference):
    return nearest_rank(abs(difference).max(axis=-1).ravel(), .95)


def encode(rgb):
    rgb = np.clip(rgb, 0, 1)
    return np.where(rgb <= .0031308, rgb * 12.92, 1.055 * rgb ** (1 / 2.4) - .055)


def neighborhood_scores(neutral, adjusted, target):
    """Screen a 256-pixel guide against a regular 1/16 sample of each image."""
    height, width = neutral.shape[:2]
    scale = min(1, 256 / max(height, width))
    rows, columns = np.ceil(np.array([height, width]) * scale).astype(int)
    y = ((np.arange(rows) + .5) * height / rows).astype(int)
    x = ((np.arange(columns) + .5) * width / columns).astype(int)
    colors = encode(neutral[y[:, None], x])
    changes = adjusted[y[:, None], x] - neutral[y[:, None], x]
    x, y = np.meshgrid(np.arange(2, width, 4), np.arange(2, height, 4))
    center = encode(neutral[y, x])
    change = adjusted[y, x] - neutral[y, x]
    error = adjusted[y, x] - target[y, x]
    before = p95(error)
    ratios = {}
    for sigma in (1 / 32, 1 / 16, 1 / 8):
        total = np.ones(x.shape, dtype=np.float32)
        correction = np.zeros_like(change)
        for radius in (4, 16, 64, 256):
            distance = radius * max(height, width) / 1024
            for angle in range(8):
                a = angle * np.pi / 4
                xx = np.clip(np.floor((x + .5 + distance * np.cos(a)) * columns / width).astype(int), 0, columns - 1)
                yy = np.clip(np.floor((y + .5 + distance * np.sin(a)) * rows / height).astype(int), 0, rows - 1)
                squared = np.sum((center - colors[yy, xx]) ** 2, axis=-1)
                weight = np.exp(-squared * (.5 / sigma ** 2))
                correction += weight[..., None] * (changes[yy, xx] - change)
                total += weight
        after = p95(error + correction / total[..., None])
        ratios[sigma] = np.log((after + .002) / (before + .002))
    return ratios


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path, help='signed cases with source hashes and Lightroom registrations')
    parser.add_argument('baseline_scores', type=Path, help='public render ledger with absolute and paired-response p95')
    parser.add_argument('decoded', type=Path, nargs='+', help='decoded public PNG directories containing manifest.json')
    args = parser.parse_args()
    calibration = {s['sourceSHA256'] for s in read(Path(__file__).with_name('highlights-strength-calibration.json'))['samples']}
    baseline = {r['id']: r for r in read(args.baseline_scores)['rows']}
    images = {}
    for folder in args.decoded:
        for record in read(folder / 'manifest.json'):
            key = Path(record['input']).stem
            if key in images:
                raise ValueError(f'Duplicate public output for {key}')
            images[key] = folder, record

    def public(key):
        folder, row = images[key]
        if digest(row['input']) != row['sha256'] or row['space'] != 'extended-linear Display-P3 D65':
            raise ValueError(f'Unexpected public output for {key}')
        pixels = np.fromfile(folder / row['output'], '<f4').reshape(row['height'], row['width'], 4)
        if not np.isfinite(pixels).all() or not np.all(pixels[..., 3] == 1):
            raise ValueError(f'Unexpected decoded pixels for {key}')
        return pixels[..., :3]

    roots = {}

    def adobe(folder, key, source, parameters, reference_hash, icc):
        if folder not in roots:
            folder_path = Path(folder)
            roots[folder] = FrozenSet(folder_path), {c['id']: c for c in read(folder_path / 'cases.json')['cases']}
        frozen, cases = roots[folder]
        case, reference = cases[key], frozen.references[key]
        if (case['parameters'] != parameters or digest(case['input']) != source or case['inputSHA256'] != source
                or digest(case['settings']) != reference['settingsSHA256'] or reference['referenceSHA256'] != reference_hash
                or frozen.decoded[key]['space'] != 'extended-linear Display-P3 D65'):
            raise ValueError(f'Unexpected Lightroom setting, source or export for {key}')
        with Image.open(Path(folder) / reference['reference']) as image:
            if hashlib.sha256(image.info['icc_profile']).hexdigest() != icc:
                raise ValueError(f'Changed Lightroom profile for {key}')
        return frozen.read(key)[..., :3]

    for control in ('Highlights2012', 'Shadows2012'):
        cases = [c for c in read(args.cases) if c['amount'] == -50 and c['control'] == control and c['source'] in calibration]
        if {c['source'] for c in cases} != calibration or len(cases) != len(calibration):
            raise ValueError(f'Expected one {control} sample for each calibration input')
        groups = {'photo': [], 'chart': []}
        for c in cases:
            key = c['id']
            entry = baseline[key]
            if entry['source'] != c['source'] or entry['control'] != control or entry['amount'] != -50:
                raise ValueError(f'Unpaired public slider or source for {key}')
            source = public(c['neutralPublic'])
            output = public(key)
            target = adobe(c['root'], key, c['source'], {control: -50}, c['referenceSHA256'], entry['icc'])
            neutral = adobe(c['neutralRoot'], c['neutralID'], c['source'], {}, c['neutralReferenceSHA256'], entry['icc'])
            if not source.shape == output.shape == target.shape == neutral.shape:
                raise ValueError(f'Mismatched image sizes for {key}')
            if (abs(p95(output - target) - entry['p95']) > 1e-8
                    or abs(p95((output - source) - (target - neutral)) - entry['response']) > 1e-8):
                raise ValueError(f'Changed adjusted or neutral pixels for {key}')
            groups['photo' if c['kind'] == 'photo' else 'chart'].append(neighborhood_scores(source, output, target))
        scores = {sigma: float(np.mean([np.mean([r[sigma] for r in group]) for group in groups.values()]))
                  for sigma in groups['photo'][0]}
        print(json.dumps(dict(control=control, sigma=min(scores, key=scores.get), scores=scores,
                              photos=len(groups['photo']), charts=len(groups['chart']))))


if __name__ == '__main__':
    main()
