"""Measure two signed Light responses and their difference at identical source pixels."""
import argparse
import json
import math
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

import numpy as np

from adaptive_data import P3_TO_ROMM
from error_metrics import nearest_rank
from paired_light import HERE, acquire, decode, p95, read
from tone_chart import digest


def summary(difference):
    """Return the per-pixel maximum RGB error and signed mean error in each channel."""
    maximum = np.max(np.abs(difference), axis=1).astype(np.float32)
    return dict(pixels=len(maximum), p95=nearest_rank(maximum, .95), meanRGBError=difference.mean(axis=0).tolist())


def continue_highlights(neutral, weaker, ratio):
    """Predict a stronger exposure step from the weaker response at each source ProPhoto extremum."""
    # Bounded log-odds fitted from the weak negative Highlights chart exports.
    black, white = .00017968, 1.15264127
    rgb = neutral @ P3_TO_ROMM.T
    indices = np.column_stack((rgb.argmin(axis=1), rgb.argmax(axis=1)))
    start = np.take_along_axis(rgb, indices, axis=1)
    end = np.take_along_axis(weaker @ P3_TO_ROMM.T, indices, axis=1)

    def coordinate(value):
        return np.log(np.maximum(value + black, 1e-9) / np.maximum(white - value, 1e-9))

    initial = coordinate(start)
    predicted = initial + ratio * (coordinate(end) - initial)
    adjusted = np.clip((white + black) / (1 + np.exp(-np.clip(predicted, -80, 80))) - black, 0, 1)
    shift = adjusted - start
    position = (neutral - start[:, :1]) / np.maximum(start[:, 1:] - start[:, :1], 1e-7)
    return shift[:, :1] + position * (shift[:, 1:] - shift[:, :1])


def measure(reports, ids, decoder, directory, control='Whites2012'):
    records = [acquire(report, identity) for report, identity in zip(reports, ids, strict=True)]
    first, second = records
    source, profile = first[0]['inputSHA256'], first[2]
    direction = -1 if control == 'Highlights2012' else 1
    if (not all(r[5] == control and r[0]['inputSHA256'] == source and r[2] == profile for r in records)
            or not 0 < direction * first[6] < direction * second[6] <= 100):
        raise ValueError(f'Expected increasing strengths of {control} with sign {direction:+d} on the same input and ICC')
    decoded, responses, evidence = {}, [], []
    reference_zero = native_baseline = None
    pairs = []
    for case, _, _, _, metrics, _, amount in records:
        paired = metrics['adjustmentResponseError']
        files = [paired['referenceBaseline'], metrics['reference'], paired['candidateBaseline'], metrics['candidate']]
        for file, value in zip(files[2:], (0, amount), strict=True):
            folder = Path(file['path']).parent
            proof = read(folder / 'render.json')
            packet = folder.parent / 'settings.json'
            if (proof['mode'] != 'adaptive' or proof['inputSHA256'] != source or proof['outputICCSHA256'] != profile
                    or proof['outputSHA256'] != file['sha256'] or proof['settingsSHA256'] != digest(packet)
                    or float(read(packet)['settings'].get(control, 0)) != value):
                raise ValueError(f'Mismatched public {control} render for {case["id"]}')
        for file in files:
            key = file['sha256']
            if key not in decoded:
                decoded[key] = decode(file['path'], decoder, directory / key)
        neutral, target, native_zero, native = [decoded[f['sha256']] for f in files]
        if (any(p.shape != neutral.shape for p in (target, native_zero, native)) or
                p95(native, target) != metrics['pixelMaxChannelError']['p95'] or
                p95(native, target, (native_zero, neutral)) != paired['pixelMaxChannelError']['p95']):
            raise ValueError(f'Cannot reproduce the original paired comparison for {case["id"]}')
        if reference_zero is None:
            reference_zero, native_baseline = neutral, native_zero
        elif (reference_zero.shape != neutral.shape or not np.array_equal(reference_zero, neutral)
              or not np.array_equal(native_baseline, native_zero)):
            raise ValueError('The two settings have different neutral pixels')
        pairs.append([pixels.reshape(-1, 3) for pixels in (neutral, target, native_zero, native)])
        responses.append((np.subtract(native, native_zero, dtype=np.float64) -
                          np.subtract(target, neutral, dtype=np.float64)).reshape(-1, 3))
        evidence.append(dict(id=case['id'], amount=amount, xmp=case['settingsSHA256'],
                             referenceNeutral=files[0]['sha256'], reference=files[1]['sha256'],
                             candidateNeutral=files[2]['sha256'], candidate=files[3]['sha256']))
    # Subtract the two signed errors before aggregating. Subtracting two p95s
    # would generally compare different pixels and could conceal a large interval error.
    interval = responses[1] - responses[0]
    luminance = reference_zero.reshape(-1, 3) @ np.array([.22897457, .69173855, .07928692])
    bands = {}
    for name, selected in [('below0.075', luminance < .075), ('0.075to0.25', (.075 <= luminance) & (luminance < .25)),
                           ('atLeast0.25', luminance >= .25)]:
        if np.any(selected):
            bands[name] = summary(interval[selected])
    result = dict(source=source, outputICC=profile, settings=evidence, weaker=summary(responses[0]),
                  stronger=summary(responses[1]), interval=summary(interval), intervalByNeutralLuminance=bands)
    if control == 'Highlights2012':
        errors = np.empty((2, len(interval)), dtype=np.float32)
        ratio = second[6] / first[6]
        for offset in range(0, len(interval), 131072):
            part = slice(offset, offset + 131072)
            zero, weak, native_zero, native_weak = (p[part].astype(float) for p in pairs[0])
            measured_response = np.subtract(pairs[1][1][part], pairs[1][0][part], dtype=np.float64)
            for error, baseline, adjusted in zip(errors, (zero, native_zero), (weak, native_weak), strict=True):
                prediction = continue_highlights(baseline, adjusted, ratio)
                error[part] = np.max(np.abs(prediction - measured_response), axis=1)
        result['projectedStrongerP95'] = dict(fromLightroomWeaker=nearest_rank(errors[0], .95),
                                              fromBrightroomWeaker=nearest_rank(errors[1], .95))
    return result


def main(control=None):
    parser = argparse.ArgumentParser(description=__doc__)
    if control is None:
        parser.add_argument('--control', choices=('Highlights2012', 'Whites2012'), required=True)
    parser.add_argument('weaker_report', type=Path)
    parser.add_argument('stronger_report', type=Path)
    parser.add_argument('--pair', action='append', nargs=2, metavar=('WEAKER_CASE', 'STRONGER_CASE'), required=True)
    parser.add_argument('--maximum-p95', type=float, metavar='ERROR',
                        help='fail if either response or the change between settings exceeds this linear RGB error')
    args = parser.parse_args()
    control = control or args.control
    reports = [p.resolve(strict=True) for p in (args.weaker_report, args.stronger_report)]
    if len({tuple(ids) for ids in args.pair}) != len(args.pair):
        parser.error('Each pair of cases must be unique')
    if args.maximum_p95 is not None and (not math.isfinite(args.maximum_p95) or args.maximum_p95 < 0):
        parser.error('--maximum-p95 must be finite and nonnegative')
    rows = []
    with TemporaryDirectory() as tmp:
        decoder = Path(tmp) / 'decode'
        subprocess.run(['xcrun', 'swiftc', '-O', HERE / 'decode.swift', '-o', decoder], check=True)
        for ids in args.pair:
            with TemporaryDirectory(dir=tmp) as directory:
                rows.append(measure(reports, ids, decoder, Path(directory), control))
    print(json.dumps(dict(units='linear Display P3, output white = 1',
                          reports=[dict(path=str(p), sha256=digest(p)) for p in reports],
                          rows=rows), indent=2, allow_nan=False))
    if args.maximum_p95 is not None:
        failures = []
        for (weaker, stronger), row in zip(args.pair, rows, strict=True):
            for label, key in [(weaker, 'weaker'), (stronger, 'stronger'), (f'{weaker} to {stronger}', 'interval')]:
                if row[key]['p95'] > args.maximum_p95:
                    failures.append(f"{label} p95 {row[key]['p95']:.6f} exceeds {args.maximum_p95:g}")
        if failures:
            parser.exit(1, '\n'.join(failures) + '\n')


if __name__ == '__main__':
    main()
