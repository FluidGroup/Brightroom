"""Compare two signed Shadows settings on the same developed input, including opposite directions."""
import argparse
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

import numpy as np

from adaptive_data import P3_TO_ROMM
from error_metrics import nearest_rank
from paired_light import HERE, acquire, decode, p95, read
from tone_chart import digest

# These are the black and white limits measured by fit-strong-shadows.py on the signed charts.
BLACK_ROOM = .000228
WHITE_LIMIT = 1.17866


def extrema(rgb):
    romm = rgb @ P3_TO_ROMM.T
    return np.column_stack((romm.min(axis=1), romm.max(axis=1)))


def log_odds(value):
    return np.log(np.maximum(value + BLACK_ROOM, 1e-8) / np.maximum(WHITE_LIMIT - value, 1e-8))


def extrapolate(weak_zero, weak, strong_zero, ratio):
    """Continue the measured log-odds change of the two ROMM extrema along the original RGB hue."""
    start = extrema(weak_zero)
    end = np.maximum(extrema(weak), 0)
    # Quantization close to black has a large effect in log odds. Weight each extremum
    # by the squared sensitivity of its linear intensity to the measured log-odds change.
    sensitivity = ((start + BLACK_ROOM) * (WHITE_LIMIT - start) + (end + BLACK_ROOM) * (WHITE_LIMIT - end))
    weights = np.maximum((sensitivity / (WHITE_LIMIT + BLACK_ROOM)) ** 2, 1e-15)
    loss = np.sum((log_odds(start) - log_odds(end)) * weights, axis=1) / weights.sum(axis=1)
    base = extrema(strong_zero)
    coordinate = np.clip(log_odds(base) - ratio * loss[:, None], -80, 80)
    estimated = np.clip((WHITE_LIMIT + BLACK_ROOM) / (1 + np.exp(-coordinate)) - BLACK_ROOM, 0, 1)
    span = base[:, 1:] - base[:, :1]
    position = (strong_zero - base[:, :1]) / np.maximum(span, 1e-8)
    return np.where(span > 1e-7, estimated[:, :1] + position * (estimated[:, 1:] - estimated[:, :1]),
                    estimated.mean(axis=1)[:, None])


def measure(reports, ids, decoder, directory):
    records = [acquire(report, identity) for report, identity in zip(reports, ids)]
    amounts = [r[6] for r in records]
    source = records[0][0]['inputSHA256']
    profile = records[0][2]
    if (any(r[5] != 'Shadows2012' for r in records) or amounts[0] == amounts[1]
            or records[1][0]['inputSHA256'] != source or records[1][2] != profile):
        raise ValueError('Expected two distinct nonzero Shadows settings with the same source and ICC')
    pairs, evidence = [], []
    shape = None
    for i, (case, _, _, _, metrics, _, _) in enumerate(records):
        paired = metrics['adjustmentResponseError']
        files = (paired['referenceBaseline'], metrics['reference'], paired['candidateBaseline'], metrics['candidate'])
        for native_file, amount in zip(files[2:], (0, amounts[i])):
            folder = Path(native_file['path']).parent
            proof = read(folder / 'render.json')
            packet = folder.parent / 'settings.json'
            if (proof['mode'] != 'adaptive' or proof['inputSHA256'] != source or proof['outputICCSHA256'] != profile
                    or proof['outputSHA256'] != native_file['sha256'] or proof['settingsSHA256'] != digest(packet)
                    or float(read(packet)['settings'].get('Shadows2012', 0)) != amount):
                raise ValueError(f'Public render does not match the selected source, profile and Shadows value in {folder}')
        pixels = [decode(f['path'], decoder, directory / f'{i}-{j}') for j, f in enumerate(files)]
        n, target, x, native = pixels
        if shape is not None and n.shape != shape:
            raise ValueError('The two settings must have the same spatial grid')
        shape = n.shape
        if (any(p.shape != n.shape for p in pixels) or p95(native, target) != metrics['pixelMaxChannelError']['p95']
                or p95(native, target, (x, n)) != paired['pixelMaxChannelError']['p95']):
            raise ValueError(f'Could not reproduce registered metrics or pixel dimensions for {ids[i]}')
        pairs.append([p.reshape(-1, 3) for p in pixels])
        evidence.append(dict(id=ids[i], amount=amounts[i], xmp=case['settingsSHA256'],
                             referenceNeutral=files[0]['sha256'], reference=files[1]['sha256'],
                             nativeNeutral=files[2]['sha256'], native=files[3]['sha256']))
    count = len(pairs[0][0])
    errors = np.empty((4, count), dtype=np.float32)
    ratio = amounts[1] / amounts[0]
    for start in range(0, count, 131072):
        part = slice(start, start + 131072)
        n0, t0, x0, e0 = [p[part].astype(float) for p in pairs[0]]
        n1, t1, x1, e1 = [p[part].astype(float) for p in pairs[1]]
        target = t1 - n1
        reference_prediction = extrapolate(n0, t0, n1, ratio) - n1
        native_prediction = extrapolate(x0, e0, x1, ratio) - x1
        native = e1 - x1
        for out, delta in zip(errors, (reference_prediction - target, native_prediction - target,
                                       native - target, (native - (e0 - x0)) - (target - (t0 - n0)))):
            out[part] = np.max(np.abs(delta), axis=1)
    if -100 <= amounts[1] < amounts[0] < 0:
        # Keep the field names used by existing negative-interval reports.
        names = ('fromMeasuredWeakerSetting', 'fromNativeWeakerSetting', 'publicStrongerSetting', 'publicIntervalOnly')
    else:
        names = ('fromMeasuredFirstSetting', 'fromNativeFirstSetting', 'publicSecondSetting', 'publicIntervalOnly')
    return dict(source=source, outputICC=profile, pixels=count, settings=evidence,
                p95MaxChannel={k: nearest_rank(e, .95) for k, e in zip(names, errors)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first_report', type=Path)
    parser.add_argument('second_report', type=Path)
    parser.add_argument('--pair', nargs=2, metavar=('FIRST_CASE', 'SECOND_CASE'), action='append', required=True)
    args = parser.parse_args()
    reports = [p.resolve(strict=True) for p in (args.first_report, args.second_report)]
    if len({tuple(ids) for ids in args.pair}) != len(args.pair):
        parser.error('Each pair of cases must be unique')
    rows = []
    with TemporaryDirectory() as tmp:
        decoder = Path(tmp) / 'decode'
        subprocess.run(['xcrun', 'swiftc', '-O', HERE / 'decode.swift', '-o', decoder], check=True)
        for ids in args.pair:
            with TemporaryDirectory(dir=tmp) as folder:
                rows.append(measure(reports, ids, decoder, Path(folder)))
    print(json.dumps(dict(reports=[{'path': str(p), 'sha256': digest(p)} for p in reports],
                          blackRoom=BLACK_ROOM, whiteLimit=WHITE_LIMIT, rows=rows), indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
