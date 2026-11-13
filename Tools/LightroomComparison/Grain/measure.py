"""Measure grain or block-mean color error in 16-bit exports decoded by Light/decode.swift.

Each input is a .rgba32f file next to its decoder manifest. The source hashes
associate measurements with the particular exports. No random phase is fitted.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def read(path):
    records = json.loads((path.parent / 'manifest.json').read_text())
    row = next(r for r in records if r['output'] == path.name)
    if row['space'] != 'extended-linear Display-P3 D65' or not row['format'].startswith('little-endian Float32 RGBA'):
        raise ValueError(f'Unexpected decoding conditions for {path}')
    with open(row['input'], 'rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
            raise ValueError(f'Source export changed for {path}')
    shape = (row['height'], row['width'], 4)
    if path.stat().st_size != 4 * np.prod(shape):
        raise ValueError(f'Truncated pixels: {path}')
    pixels = np.memmap(path, dtype='<f4', mode='r', shape=shape)
    for start in range(0, shape[0], 128):
        stripe = pixels[start:start+128]
        if not np.isfinite(stripe).all() or not np.all(abs(stripe[..., 3] - 1) < 1e-6):
            raise ValueError(f'Nonfinite or nonopaque pixels: {path}')
    return pixels[..., :3], row


def encoded_romm(pixels):
    matrix = [[.63169122, .21392818, .15438059], [.08320432, .88585751, .03093817],
              [-.00127273, .05075510, .95051763]]
    rgb = pixels @ np.asarray(matrix).T
    return np.where(rgb <= .0031308, 12.92 * rgb, 1.055 * np.maximum(rgb, 0) ** (1 / 2.4) - .055)


def detail_change(source):
    # Sigma 0.58 in a point-sampled Gaussian describes the 24 MP Adobe edge.
    weights = np.exp(-.5 * (np.arange(-2, 3) / .58) ** 2)
    weights /= weights.sum()
    result = source
    for axis in (0, 1):
        result = sum(w * np.roll(result, offset, axis) for offset, w in zip(range(-2, 3), weights))
    return result - source


def regions(shape, layout):
    height, width = shape[:2]
    if layout == 'chart':
        if (height, width) != (256, 1024):
            raise ValueError('The A10 chart layout requires its 1024×256 pair')
        yield 'encoded-gray-ramp', (0, 0, width, 64)
        yield 'linear-gray-ramp', (0, 64, width, 64)
        yield 'color-lattice', (0, 128, width, 128)
    elif layout == 'patches':
        yield 'gray-patches', (0, 0, width, height // 2)
        yield 'chromatic-edges', (0, height // 2, width, height - height // 2)
    elif layout == 'photo':
        side = min(256, width // 4, height // 4)
        if side < 16:
            raise ValueError('The photo is too small to measure four-pixel correlations across a 4×4 grid')
        for y in np.linspace(0, height - side, 4, dtype=int):
            for x in np.linspace(0, width - side, 4, dtype=int):
                yield 'grid', (int(x), int(y), side, side)
    else:
        raise ValueError(layout)


def texture(off, on, layout):
    groups = {}
    for label, (x, y, w, h) in regions(off.shape, layout):
        a, b = (encoded_romm(img[y:y+h, x:x+w]) for img in [off, on])
        change = b - a
        mid = (a[..., 1] > .14) & (a[..., 1] < .86)
        mid[:3] = mid[-3:] = mid[:, :3] = mid[:, -3:] = False
        source_blur = detail_change(a)
        # A monochromatic grain sample cancels in differences of interior RGB channels.
        # The scalar measures image softening separately from the stochastic signal.
        valid = mid & (a.min(-1) > .14) & (a.max(-1) < .86)
        predictor = (source_blur[..., :2] - source_blur[..., 2:])[valid]
        observed = (change[..., :2] - change[..., 2:])[valid]
        groups.setdefault(label, []).append((change, source_blur, mid,
            np.sum(predictor * observed), np.sum(predictor ** 2), [x, y, w, h]))
    result = {}
    for label, parts in groups.items():
        energy = sum(p[4] for p in parts)
        # Gray ramps have no chromatic edges that identify the softening gain.
        gain = sum(p[3] for p in parts) / energy if energy > 1e-4 else None
        all_values = []
        neighbor_pairs = {i: [] for i in (1, 2, 4)}
        for change, source_blur, mid, *_ in parts:
            signal = change[..., 1] - (gain or 0) * source_blur[..., 1]
            all_values.append(signal[mid])
            for step, pairs in neighbor_pairs.items():
                for field, mask in [(signal, mid), (signal.T, mid.T)]:
                    both = mask[:, step:] & mask[:, :-step]
                    pairs.append(np.stack([field[:, :-step][both], field[:, step:][both]]))
        values = np.concatenate(all_values)
        if len(values) < 2:
            raise ValueError(f'Insufficient midtone pixels: {label}')
        std = values.std()
        ac = {}
        for step, pairs in neighbor_pairs.items():
            a, b = np.concatenate(pairs, axis=1)
            ac[step] = float(np.corrcoef(a, b)[0, 1]) if len(a) > 1 and a.std() and b.std() else None
        result[label] = dict(regions=[p[5] for p in parts], midtonePixels=len(values),
            encodedMean=float(values.mean()), encodedStandardDeviation=float(std),
            kurtosis=float(np.mean(((values-values.mean()) / std) ** 4)) if std else None,
            neighborCorrelation=ac, chromaticDetailBlurGain=float(gain) if gain is not None else None)
    return result


def block_errors(reference, candidate):
    # A block mean suppresses phase differences. It can still contain grain
    # energy; publish the full-resolution metric from A10/run.py alongside it.
    result = {}
    h, w = reference.shape[:2]
    if min(h, w) < 32:
        raise ValueError('The block comparison requires at least one 32×32 block')
    for size in (4, 16, 32):
        usable_width = w // size * size
        values = []
        for y in range(0, h - size + 1, size):
            def means(image):
                block = image[y:y+size, :usable_width].reshape(size, -1, size, 3)
                return block.mean(axis=(0, 2), dtype=np.float64)
            values.append(abs(means(reference) - means(candidate)).max(-1))
        values = np.concatenate(values)
        result[size] = dict(blocks=len(values), p50=float(np.median(values)), p95=float(np.quantile(values, .95)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('metric', choices=['chart', 'patches', 'photo', 'blocks'])
    parser.add_argument('baseline', type=Path, help='grain-off image, or reference for blocks')
    parser.add_argument('adjusted', type=Path, help='grain-on image, or candidate for blocks')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    a, first = read(args.baseline)
    b, second = read(args.adjusted)
    if a.shape != b.shape:
        raise ValueError('The two exports must have identical dimensions')
    measures = block_errors(a, b) if args.metric == 'blocks' else texture(a, b, args.metric)
    with args.output.open('x') as stream:
        json.dump(dict(metric=args.metric, baseline=first, adjusted=second, measurements=measures),
                  stream, indent=2, allow_nan=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
