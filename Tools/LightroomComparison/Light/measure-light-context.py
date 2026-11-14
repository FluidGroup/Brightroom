"""Measure the change of a single Light slider at identical source RGBs with different surroundings."""
import argparse
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

import numpy as np
from PIL import Image
from scipy.ndimage import distance_transform_edt, gaussian_filter, maximum_filter, minimum_filter

from adaptive_data import P3_TO_ROMM
from error_metrics import nearest_rank
from paired_light import HERE, acquire, decode, p95, read
from tone_chart import digest

LUMINANCE = np.array([.22897457, .69173855, .07928692])


def dark_edge_bands(source_y, loss, levels):
    """Measure signed loss in a narrow source-tone interval as distance from dark regions increases."""
    return edge_bands(source_y, loss, levels, bright=False)


def edge_bands(source_y, loss, levels, *, bright):
    """Measure same-tone pixels at increasing distances from a sustained bright or dark area."""
    def encoded(y):
        return np.where(y <= .0031308, 12.92 * y, 1.055 * np.maximum(y, 0) ** (1 / 2.4) - .055)

    scale = max(source_y.shape) / 1024
    window = 2 * round(2 * scale) + 1
    extreme = (minimum_filter if bright else maximum_filter)(encoded(source_y), size=window, mode='nearest')
    side = 'bright' if bright else 'dark'
    measurements = []
    for level in levels:
        # The entire window must cross the threshold. A single contrasting pixel
        # would give nearby pixels an artificially short distance.
        region = extreme > encoded(level) + .16 if bright else extreme < encoded(level) - .16
        selected = np.abs(source_y - level) <= .005
        bands = []
        if region.any() and selected.any():
            distances = distance_transform_edt(~region)[selected] / scale
            adobe = loss['lightroom'][selected]
            native = loss['brightroom'][selected]
            limits = (0, 4, 16, 64, 256)
            for start, stop in zip(limits, (*limits[1:], np.inf)):
                band = (distances >= start) & (distances < stop)
                row = dict(fromPer1024=start, toPer1024=int(stop) if np.isfinite(stop) else None,
                           pixels=int(band.sum()))
                if band.any():
                    delta = native[band] - adobe[band]
                    row.update(lightroomMedianLoss=float(np.median(adobe[band])),
                               brightroomMedianLoss=float(np.median(native[band])),
                               medianExcessLoss=float(np.median(delta)),
                               p95AbsoluteLossError=nearest_rank(np.abs(delta), .95))
                bands.append(row)
        measurements.append({'linearP3Luminance': level, 'halfWidth': .005, f'{side}Pixels': int(region.sum()),
                             'selectedPixels': int(selected.sum()), 'bands': bands})
    return {'encodedLuminanceRise' if bright else 'encodedLuminanceDrop': .16,
            f'{side}WindowPixels': window, 'measurements': measurements}


def channel_bands(source, source_y, neutral, reference, native_neutral, native, levels):
    """Group by the unchanged input, then compare each engine's change from its own neutral."""
    measurements = []
    for level in levels:
        selected = np.abs(source_y - level) <= .005
        pixels = source[selected].astype(float)
        romm = pixels @ P3_TO_ROMM.T
        peak = romm.max(axis=1)
        chroma = np.clip(np.ptp(romm, axis=1) / (np.maximum(peak, 0) + .025), 0, 1)
        adobe_loss = neutral[selected].astype(float) - reference[selected]
        native_loss = native_neutral[selected].astype(float) - native[selected]
        bands = []
        for lower, upper in ((0, .15), (.15, .55), (.55, 1)):
            band = (chroma >= lower) & ((chroma < upper) if upper < 1 else (chroma <= upper))
            row = dict(fromChroma=lower, toChroma=upper, pixels=int(band.sum()))
            if band.any():
                difference = native_loss[band] - adobe_loss[band]
                brightness = difference @ LUMINANCE
                color = difference - brightness[:, None]
                row.update(lightroomMeanRGBLoss=adobe_loss[band].mean(axis=0).tolist(),
                           brightroomMeanRGBLoss=native_loss[band].mean(axis=0).tolist(),
                           p95RGBError=nearest_rank(np.abs(difference).max(axis=1), .95),
                           p95LuminanceError=nearest_rank(np.abs(brightness), .95),
                           p95ColorErrorAtMatchedLuminance=nearest_rank(np.abs(color).max(axis=1), .95))
            bands.append(row)
        measurements.append(dict(linearP3Luminance=level, halfWidth=.005, selectedPixels=len(pixels), bands=bands))
    return measurements


def measure(report, identity, decoder, work, edge_levels=(), bright_levels=(), color_levels=()):
    """Choose one pair per source code before inspecting either engine's adjusted pixels."""
    case, target, icc, _, metrics, control, amount = acquire(report, identity)
    source = Path(case['input'])
    source_dir = work / 'source'
    subprocess.run([decoder, source_dir, '--native-pixels', source], check=True, stdout=subprocess.DEVNULL)
    info, = read(source_dir / 'manifest.json')
    if info['sha256'] != case['inputSHA256']:
        raise ValueError(f'Source changed while measuring {identity}')
    height, width = info['height'], info['width']
    stride = info['bytesPerPixel']
    storage = np.memmap(source_dir / info['nativePixels'], 'u1', 'r')
    keys = np.ndarray((height, width), dtype='V6', buffer=storage, offset=info['rgbOffset'],
                      strides=(info['bytesPerRow'], stride)).ravel()
    paired = metrics['adjustmentResponseError']
    neutral = decode(paired['referenceBaseline']['path'], decoder, work / 'neutral')
    native_neutral = decode(paired['candidateBaseline']['path'], decoder, work / 'public-neutral')
    reference = decode(target, decoder, work / 'adobe')
    native = decode(metrics['candidate']['path'], decoder, work / 'public')
    if not native.shape == reference.shape == neutral.shape == native_neutral.shape == (height, width, 3):
        raise ValueError(f'Missing a matching 16-bit pixel grid for {identity}')
    if (p95(native, reference) != metrics['pixelMaxChannelError']['p95']
            or p95(native, reference, (native_neutral, neutral)) != paired['pixelMaxChannelError']['p95']):
        raise ValueError(f'Could not reproduce the registered whole-image measurements for {identity}')

    y = neutral @ LUMINANCE
    loss = {'lightroom': y - reference @ LUMINANCE,
            'brightroom': native_neutral @ LUMINANCE - native @ LUMINANCE}
    log_y = (1 + np.log(np.maximum(y, .0001)) / 9.3).astype('f4')
    scale = min(1, 256 / max(height, width))
    reduced = Image.fromarray(log_y).resize((max(1, round(width * scale)), max(1, round(height * scale))),
                                            Image.Resampling.BOX)
    ordered = np.argsort(keys, kind='stable')
    colors = keys[ordered]
    start = np.flatnonzero(np.r_[True, colors[1:] != colors[:-1]])
    stop = np.r_[start[1:], len(colors)]
    levels = y.ravel()[ordered[start]]
    eligible = (stop - start >= 2) & (levels > .015) & (levels < .90)
    results = []
    for radius in (16, 64):
        blurred = gaussian_filter(np.asarray(reduced), sigma=radius * max(height, width) * scale / 1024,
                                  mode='nearest')
        surround = np.asarray(Image.fromarray(blurred).resize((width, height), Image.Resampling.BILINEAR)).ravel()
        # Within each source color, compare the darkest and lightest surrounding region.
        order = np.lexsort((surround, keys))
        low, high = order[start[eligible]], order[stop[eligible] - 1]
        selected = surround[high] - surround[low] > .03
        low, high = low[selected], high[selected]
        result = dict(radiusPer1024=radius, pairs=len(low))
        if len(low):
            if not np.array_equal(keys[low], keys[high]):
                raise ValueError('Mismatched source pixel bytes')
            differences = {}
            for name, field in loss.items():
                difference = field.ravel()[high] - field.ravel()[low]
                differences[name] = difference
                result[name] = dict(meanSigned=float(np.mean(difference)),
                                    p95Absolute=nearest_rank(np.abs(difference), .95),
                                    fractionBelow0001=float(np.mean(np.abs(difference) < .0001)))
            result['p95SpatialResponseError'] = nearest_rank(
                np.abs(differences['brightroom'] - differences['lightroom']), .95)
        results.append(result)
    result = dict(id=identity, control=control, amount=amount, sourceSHA256=case['inputSHA256'],
                  xmpSHA256=case['settingsSHA256'], referenceSHA256=metrics['reference']['sha256'],
                  outputSHA256=metrics['candidate']['sha256'], referenceICC=icc, neighborhoods=results)
    if edge_levels or bright_levels or color_levels:
        source_pixels = np.memmap(source_dir / info['output'], '<f4', 'r', shape=(height, width, 4))
        source_rgb = source_pixels[..., :3]
        source_y = source_rgb @ LUMINANCE
        if edge_levels:
            result['darkEdgeDistance'] = dark_edge_bands(source_y, loss, edge_levels)
        if bright_levels:
            result['brightEdgeDistance'] = edge_bands(source_y, loss, bright_levels, bright=True)
        if color_levels:
            result['sameLuminanceColorBands'] = channel_bands(source_rgb, source_y, neutral, reference,
                                                              native_neutral, native, color_levels)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path, help='paired report.json from A10/run.py')
    parser.add_argument('--case-id', required=True, action='append')
    parser.add_argument('--edge-luminance', type=float, action='append', default=[],
                        help='also measure loss by distance from a dark region at this linear P3 luminance')
    parser.add_argument('--bright-edge-luminance', type=float, action='append', default=[],
                        help='also measure loss by distance from a bright region at this linear P3 luminance')
    parser.add_argument('--color-luminance', type=float, action='append', default=[],
                        help='also compare RGB loss by source chroma at this linear P3 luminance')
    args = parser.parse_args()
    if len(set(args.case_id)) != len(args.case_id):
        parser.error('Case IDs must be unique')
    if any(not 0 <= level <= 1 for level in args.edge_luminance + args.bright_edge_luminance + args.color_luminance):
        parser.error('Source luminance must be finite and between 0 and 1')
    report = args.report.resolve(strict=True)
    rows = []
    with TemporaryDirectory() as directory:
        decoder = Path(directory) / 'decode'
        subprocess.run(['xcrun', 'swiftc', '-O', HERE / 'decode.swift', '-o', decoder], check=True)
        for identity in args.case_id:
            with TemporaryDirectory(dir=directory) as work:
                rows.append(measure(report, identity, decoder, Path(work), args.edge_luminance, args.bright_edge_luminance,
                                    args.color_luminance))
    print(json.dumps(dict(report=str(report), reportSHA256=digest(report), rows=rows),
                     indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
