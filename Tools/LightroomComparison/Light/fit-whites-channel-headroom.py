"""Calibrate the influence of colored highlights using the registered +50 synthetic lattice."""
import argparse
import json
from pathlib import Path
import re
import subprocess

import numpy as np

from adaptive_data import P3_TO_ROMM
from tone_chart import digest, registered_chart


def encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def colored_white_coverage(source, manifest, directory):
    """Measure the excess final 32-code interpolation weight of the brightest linear ROMM channel."""
    if (manifest['sha256'] != source or digest(manifest['input']) != source
            or manifest['space'] != 'extended-linear Display-P3 D65'
            or manifest['format'] != 'little-endian Float32 RGBA, opaque, top-to-bottom'):
        raise ValueError(f'Invalid developed source {source}')
    rgba = np.memmap(directory / manifest['output'], '<f4', 'r', shape=(manifest['height'], manifest['width'], 4))
    if not np.isfinite(rgba).all() or not np.all(rgba[..., 3] == 1):
        raise ValueError(f'Expected a finite, opaque chart for {source}')
    p3 = rgba[..., :3]
    luminance = np.clip(p3, 0, 1) @ np.array([.2289746, .6917385, .0792869], dtype='f4')
    highest = np.max(p3 @ P3_TO_ROMM.astype('f4').T, axis=2)

    def white_weight(linear):
        return np.clip(1 + (encode(linear) - 1) * 31, 0, 1)

    return float(np.mean(np.maximum(white_weight(highest) - white_weight(luminance), 0), dtype='f8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('references', type=Path, help='registered adjustments-001')
    parser.add_argument('--decoded-inputs', type=Path, nargs='+', required=True,
                        help='source decode directories for the 17 calibration scenes and the original color lattice')
    parser.add_argument('--gray-probe', type=Path, required=True,
                        help='whites-gray-ramp.swift compiled against the current public feature')
    parser.add_argument('--check', type=Path, help='verify the measured range and log response in the Metal source')
    args = parser.parse_args()
    calibration = json.loads(Path(__file__).with_name('strong-whites-calibration.json').read_text())
    neutral, zero = registered_chart(args.references, 'adjust-chart-', 'Whites2012', 0)
    target, adjusted = registered_chart(args.references, 'adjust-chart-', 'Whites2012', 50)
    if zero['source'] != adjusted['source'] or zero['profile'] != adjusted['profile']:
        raise ValueError('The neutral and +50 exports must share their source and output profile')
    references = json.loads((args.references / 'references.json').read_text())['references']
    settings = {r['id']: {k: v for k, v in r['resolvedSettings'].items() if k not in ('Whites2012', 'RawFileName')}
                for r in references if r['id'] in (zero['id'], adjusted['id'])}
    if settings[zero['id']] != settings[adjusted['id']]:
        raise ValueError('The two exports must have identical adjustments apart from Whites')
    sources = {s['sourceSHA256'] for s in calibration['scenes']}
    if len(sources) != 17 or zero['source'] in sources:
        raise ValueError('Expected the original lattice in addition to the 17 measured synthetic scenes')
    coverage = {}
    for directory in args.decoded_inputs:
        for row in json.loads((directory / 'manifest.json').read_text()):
            source = row['sha256']
            if source in sources or source == zero['source']:
                coverage[source] = colored_white_coverage(source, row, directory)
                if source == zero['source']:
                    lattice = Path(row['input'])
    if set(coverage) != sources | {zero['source']}:
        raise ValueError('Incomplete synthetic source set')
    nominal = json.loads(subprocess.check_output([args.gray_probe.resolve(), lattice], text=True))
    # Both paths use the 32 nodes in the upper gray ramp of the original chart.
    xs = np.arange(32) * 33
    start = encode(neutral[32, xs, 1].astype('f8'))
    np.testing.assert_allclose(nominal['neutral'], np.arange(32) / 31, atol=1 / 65535, rtol=0)
    np.testing.assert_array_equal(np.rint(start * 31), np.arange(32))
    measured = np.mean(encode(target[32, xs, 1].astype('f8')) - start)
    gray = np.mean(np.asarray(nominal['whites50']) - np.asarray(nominal['neutral']))
    if not 0 < measured < gray:
        raise ValueError('Expected a smaller positive Whites displacement for the colored chart')
    log_gain = float(np.log(measured / gray) / calibration['amountLaw'][1][1])
    limits = [max(coverage[s] for s in sources), coverage[zero['source']]]
    if args.check:
        line = re.search(r'chromaticHeadroom = float3\(([^)]+)\)', args.check.read_text())
        if line is None:
            raise ValueError('Missing chromatic headroom calibration')
        values = [float(s.strip().removesuffix('f')) for s in line[1].split(',')]
        np.testing.assert_allclose(values[:2], limits, atol=5.1e-7, rtol=0)
        # The gray probe runs in the host GPU's working precision.
        np.testing.assert_allclose(values[2], log_gain, atol=.002, rtol=0)
    print(json.dumps(dict(calibrationScenes=len(sources),source=zero['source'],reference=adjusted['reference'],
                          minimumCoverage=limits[0],maximumCoverage=limits[1],referenceDisplacement50=measured,
                          achromaticDisplacement50=gray,logResponse75=log_gain), indent=2))


if __name__ == '__main__':
    main()
