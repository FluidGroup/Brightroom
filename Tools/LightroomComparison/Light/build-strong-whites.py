"""Pack strong Whites from registered synthetic Lightroom exports and global luminance measurements."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile

import numpy as np
from scipy.interpolate import PchipInterpolator
from scipy.spatial import cKDTree
from adaptive_data import FrozenSet


P3_TO_ROMM = np.array([[.63169122, .21392818, .15438059],
                       [.08320432, .88585751, .03093817],
                       [-.00127273, .05075510, .95051763]])


def encode(linear):
    return np.where(linear <= .0031308, 12.92 * linear, 1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)


def cube(acquisition, case):
    # The centered 512×256 patch contains all 32³ colors, red fastest, with four pixels per color.
    patch = acquisition.read(case)[384:640, 256:768, :3].astype('f8')
    return patch.reshape(128, 2, 256, 2, 3).mean(axis=(1, 3)).reshape(32**3, 3)


def array_digest(values):
    stream = io.BytesIO()
    np.save(stream, values, allow_pickle=False)
    return hashlib.sha256(stream.getbuffer()).hexdigest()


def coarse_histogram(mass):
    """Distribute each fine bin between adjacent centers to preserve sub-bin brightness changes."""
    position = np.arange(128) * (15 / 127)
    weights = np.maximum(1 - abs(position[:, None] - np.arange(16)), 0)
    return mass @ weights


def verify_spatial_measurements(calibration, inputs, peak_references, gray_axis):
    """Recompute the distribution features, white points and both registered gray ramps."""
    from scipy.ndimage import gaussian_filter

    decoded = {r['sha256']: r for r in json.loads((inputs / 'manifest.json').read_text())}

    def source_pixels(digest):
        row = decoded[digest]
        with Path(row['input']).open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                raise ValueError(f'Changed Whites input {digest}')
        if row['space'] != 'extended-linear Display-P3 D65':
            raise ValueError(f'Unexpected decoded color space for {digest}')
        return np.memmap(inputs / row['output'], dtype='<f4', mode='r',
                         shape=(row['height'], row['width'], 4))[..., :3]

    guide = calibration['distributionGuide']
    ranks = [.01, .05, .1, .2, .3, .4, .5, .6, .7, .8, .9, .95, .99]
    weights = np.array([.2289746, .6917385, .0792869], dtype=np.float32)
    for scene in calibration['scenes']:
        code = encode(np.clip(source_pixels(scene['sourceSHA256']), 0, 1) @ weights)
        blurred = gaussian_filter(code, max(code.shape) * guide['blurSigmaPerLongEdge'], mode='nearest')
        detail = np.mean((blurred - code) ** 2) / max(np.var(code), guide['varianceFloor'])
        signal = code + np.clip(detail, 0, 1) * (blurred - code)
        # Deposit into adjacent bins as in brightroomWhitesHistogram. Use the
        # same quantile convention for a constant field and for a populated bin.
        code = np.clip(signal.ravel(), 0, 1) * 127
        lower = code.astype(int)
        fraction = code - lower
        mass = (np.bincount(lower, weights=1 - fraction, minlength=128)
                + np.bincount(np.minimum(lower + 1, 127), weights=fraction, minlength=128))
        mass /= mass.sum()
        cumulative = np.cumsum(mass)
        index = np.minimum(cumulative.searchsorted(ranks), 127)
        within = (ranks - cumulative[index] + mass[index]) / np.maximum(mass[index], 1e-12)
        summary = np.r_[mass @ (np.arange(128) / 127), np.clip((index - .5 + within) / 127, 0, 1)]
        np.testing.assert_allclose(summary, scene['encodedLuminance'], rtol=0, atol=1e-6)
        np.testing.assert_allclose(coarse_histogram(mass), scene['luminanceHistogram'], rtol=0, atol=1e-6)

    acquisition = FrozenSet(peak_references)
    registration = json.loads((peak_references / 'cases.json').read_text())
    cases = {r['id']: r for r in registration['cases']}
    fields = [(gray, 100) for gray in calibration['peakGray']] + [(calibration['darkField75'], 75)]
    for gray, amount in fields:
        identity = gray['id']
        case = cases[identity]
        if (case['inputSHA256'] != gray['inputSHA256'] or case['parameters'] != {'Whites2012': amount}
                or acquisition.references[identity]['referenceSHA256'] != gray['referenceSHA256']):
            raise ValueError(f'Unexpected Whites gray reference {identity}')
        measured = [np.median(source_pixels(gray['inputSHA256'])), np.median(acquisition.read(identity)[..., :3])]
        np.testing.assert_allclose(measured, [gray['inputLinearP3'], gray['outputLinearP3']], rtol=0, atol=1e-7)

    def ramp_row(reference, settings, row, columns):
        dataset = acquisition
        identity = reference['id']
        if identity in cases:
            case = cases[identity]
        else:
            # The dark ramp's neutral export belongs to an earlier acquisition.
            reused = next(r for r in registration['reusedReferences'] if r['id'] == identity)
            path = Path(reused['path'])
            dataset = FrozenSet(path.parents[2])
            prior = json.loads((dataset.root / 'cases.json').read_text())
            case = next(r for r in prior['cases'] if r['id'] == identity)
            if (reused['sha256'] != reference['referenceSHA256']
                    or dataset.root / dataset.references[identity]['reference'] != path):
                raise ValueError(f'Unexpected reused gray ramp {identity}')
        if (case['parameters'] != settings or case['settingsSHA256'] != reference['settingsSHA256']
                or case['inputSHA256'] != reference['sourceSHA256']
                or dataset.references[identity]['referenceSHA256'] != reference['referenceSHA256']):
            raise ValueError(f'Unexpected gray ramp registration {identity}')
        return dataset.read(identity)[row, columns, :3].mean(axis=1)

    for name in ('surroundRamp', 'darkRamp'):
        ramp = calibration[name]
        x = ramp['sampleX']
        columns = slice(x, x + ramp['sampleWidth'])
        neutral, bright = [ramp_row(r, settings, ramp['sampleRow'], columns)
                           for r, settings in zip(ramp['references'], [{}, {'Whites2012': 100}], strict=True)]
        if np.any(np.diff(neutral) < 0):
            raise ValueError(f'Expected an ascending neutral ramp for {name}')
        if name == 'surroundRamp':
            neutral, bright = np.r_[0, neutral, 1], np.r_[0, bright, 1]
        elif bright[-1] < .999:
            raise ValueError('The measured dark ramp must reach white at its upper endpoint')
        measured = np.interp(gray_axis, neutral, bright, left=0, right=1)
        np.testing.assert_allclose(measured, ramp['outputLinearP3'], rtol=0, atol=1e-7)


def extend_with_gray_ramp(neutral, chart_delta, gray_nodes, ramp):
    """Transfer the measured gray change to the extrema of the strong color chart in linear ROMM."""
    original = neutral @ P3_TO_ROMM.T
    chart = (neutral + chart_delta) @ P3_TO_ROMM.T
    lower, upper = original.min(axis=1), original.max(axis=1)
    hue = (original - lower[:, None]) / np.maximum(upper - lower, 1e-12)[:, None]
    gray = neutral[gray_nodes].mean(axis=1)
    measured = np.asarray(ramp['outputLinearP3'])
    if measured.shape != gray.shape or not np.isfinite(measured).all() or np.any(np.diff(measured) < 0):
        raise ValueError('Invalid strong Whites gray ramp')
    extra = measured - (neutral + chart_delta)[gray_nodes].mean(axis=1)

    def movement(endpoint, adjusted):
        # Preserve the measured chart color at the join, including any ICC roundoff.
        shift = np.interp(endpoint, gray, extra)
        return np.clip(adjusted + shift, 0, 1) - np.clip(adjusted, 0, 1)

    low_change = movement(lower, chart.min(axis=1))
    high_change = movement(upper, chart.max(axis=1))
    change = low_change[:, None] + hue * (high_change - low_change)[:, None]
    delta = chart_delta + change @ np.linalg.inv(P3_TO_ROMM).T
    delta[gray_nodes] = (measured - gray)[:, None]
    return delta, float(np.mean(encode(measured) - encode(gray)))


def pack_response_axis(knots, responses, neutral):
    """Choose layers minimizing squared RGB error along the measured displacement axis.

    A shape-preserving cubic interpolates each of the 32³ measured colors offline.
    The renderer blends two neighboring layers linearly. Select their positions by
    integrating the error of that blend across both the displacement axis and RGB.
    """
    # Budget one chart layer per observed strength, including the identity. Measured
    # breakpoints between uniform samples can otherwise disappear from the packed shoulder.
    layer_count = len(knots)
    uniform = np.linspace(knots[0], knots[-1], 65)
    grid = np.union1d(uniform, knots)
    tables = PchipInterpolator(knots, responses, axis=0)(grid)
    colors = tables.reshape(len(grid), -1)
    # Inner products let every trial interval reuse the same full-color measurements.
    gram = (colors @ colors.T) / colors.shape[1]
    cost = np.full((len(grid), len(grid)), np.inf)
    for i in range(len(grid) - 1):
        for j in range(i + 1, len(grid)):
            region = slice(i, j + 1)
            fraction = (grid[region] - grid[i]) / (grid[j] - grid[i])
            weights = np.column_stack((1 - fraction, fraction))
            ends = [i, j]
            cross = gram[region][:, ends] @ weights.T
            residual = gram[region, region] - cross - cross.T + weights @ gram[np.ix_(ends, ends)] @ weights.T
            norm = residual.diagonal()
            # For linear error e over an interval, its mean square is (a² + ab + b²) / 3.
            cost[i, j] = np.diff(grid[region]) @ (norm[:-1] + residual.diagonal(1) + norm[1:]) / 3

    loss = np.full((layer_count, len(grid)), np.inf)
    previous = np.zeros(loss.shape, dtype=int)
    loss[0, 0] = 0
    for layer in range(1, layer_count):
        for j in range(layer, len(grid)):
            candidates = loss[layer - 1, :j] + cost[:j, j]
            previous[layer, j] = best = int(np.argmin(candidates))
            loss[layer, j] = candidates[best]
    indices = [len(grid) - 1]
    for layer in range(layer_count - 1, 0, -1):
        indices.append(previous[layer, indices[-1]])
    indices.reverse()
    positions = grid[indices]
    packed = tables[indices]

    # Work in linear ROMM, the output RGB space of the reference TIFFs. Once
    # an endpoint clips, its stored white value no longer measures its slope.
    # Keep the two preceding unsaturated observations when interpolating that
    # transition. The renderer clamps the interpolated endpoints to white.
    source = neutral @ P3_TO_ROMM.T
    darkest, brightest = source.argmin(axis=1), source.argmax(axis=1)
    pixel = np.arange(len(source))
    output = (neutral + np.asarray(responses)) @ P3_TO_ROMM.T
    endpoints = np.stack((output[:, pixel, darkest], output[:, pixel, brightest]), axis=-1)
    # A measured 16-bit white can decode to 0.999939 after the ICC round trip.
    last = np.max(np.where(endpoints < 1 - .00012, np.arange(len(knots))[:, None, None], -1), axis=0)
    has_plateau = (last >= 1) & (last < len(knots) - 1)
    last = np.maximum(last, 1)
    channel = np.arange(2)
    y = endpoints[last, pixel[:, None], channel]
    rise = np.maximum(y - endpoints[last - 1, pixel[:, None], channel], 0)
    slope = rise / (knots[last] - knots[last - 1])
    distance = knots[:, None, None] - knots[last]
    # Beyond a single calibration grid step the white samples provide no new
    # slope information. A longer extrapolation can make a near-white channel
    # fall again after the neighboring colors are interpolated.
    grid_step = uniform[1] - uniform[0]
    continued = np.clip(y + slope * distance, 1, 1 + np.minimum(rise, slope * grid_step))
    clipped = np.minimum(endpoints, 1)
    extended = np.where(has_plateau & (distance > 0), continued, clipped)
    correction = (PchipInterpolator(knots, extended)(positions)
                  - PchipInterpolator(knots, clipped)(positions))
    low = source.min(axis=1)[:, None]
    hue = (source - low) / np.maximum(np.ptp(source, axis=1)[:, None], 1e-7)
    rgb = correction[..., :1] + hue * (correction[..., 1:] - correction[..., :1])
    return positions, packed + rgb @ np.linalg.inv(P3_TO_ROMM).T


def extend_to_dark_field(neutral, chart_delta, gray_nodes, ramps, field):
    """Extend the last gray-ramp interval to the measured +75 dark-field output."""
    first, last = (np.asarray(r['outputLinearP3']) for r in ramps)
    gray = neutral[gray_nodes].mean(axis=1)
    x = field['inputLinearP3']
    # The runtime interpolates table deltas at this encoded-P3 coordinate.
    location = encode(x) * (len(gray) - 1)
    levels = np.arange(len(gray))
    current = x + np.interp(location, levels, last - gray)
    step = np.interp(location, levels, last - first)
    if step <= 0 or current >= field['outputLinearP3'] or np.any(last < first - 1e-6):
        raise ValueError('Expected the +75 dark gray to extend the last two increasing ramps')
    fraction = (field['outputLinearP3'] - current) / step
    extended = np.clip(last + fraction * (last - first), 0, 1)
    return extend_with_gray_ramp(neutral, chart_delta, gray_nodes, {'outputLinearP3': extended})


def ordered_endpoints(tables, levels):
    """Resample the measured changes of the lowest and highest linear ROMM channels.

    After sorting the input channels, all six permutations share the same two
    responses. The measured P3 colors form an irregular cloud in these coordinates.
    Fit a local quadratic at each regular lattice node, reusing its weights across
    both endpoints and every strength. On the neutral diagonal use the gray ramp.
    """
    blue, green, red = np.indices((32, 32, 32)).reshape(3, -1) / 31
    code = np.column_stack((red, green, blue))
    linear = np.where(code <= .04045, code / 12.92, ((code + .055) / 1.055) ** 2.4)
    romm = linear @ P3_TO_ROMM.T
    measured = np.sort(encode(romm), axis=1)
    nodes = np.arange(len(romm))
    low, high = romm.argmin(axis=1), romm.argmax(axis=1)
    deltas = np.asarray(tables) @ P3_TO_ROMM.T
    endpoints = np.stack((deltas[:, nodes, low], deltas[:, nodes, high]), axis=-1)

    # The Metal reader uses the same order: high triangular slices, then middle rows.
    hi, mid, lo = np.indices((levels, levels, levels))
    ordered = (lo <= mid) & (mid <= hi)
    grid = np.column_stack((lo[ordered], mid[ordered], hi[ordered])) / (levels - 1)
    result = np.empty((len(tables), len(grid), 2), dtype='<f2')
    tree = cKDTree(measured)
    for start in range(0, len(grid), 1024):
        chunk = grid[start:start + 1024]
        distances, neighbors = tree.query(chunk, k=48)
        radius = np.maximum(distances[:, -1:], 1e-8)
        offsets = (measured[neighbors] - chunk[:, None, :]) / radius[:, :, None]
        terms = [np.ones_like(offsets[:, :, :1]), offsets]
        terms += [offsets[:, :, i:i+1] * offsets[:, :, j:j+1] for i in range(3) for j in range(i + 1)]
        design = np.concatenate(terms, axis=2)
        weights = (1 - (distances / radius) ** 2) ** 2 + .001
        normal = design.transpose(0, 2, 1) @ (weights[:, :, None] * design)
        # Dampen curvature outside the measured cloud, where a quadratic is poorly constrained.
        ridge = np.diag([1e-10] + [1e-6] * 3 + [2e-5] * 6)
        normal += ridge * (1 + 32 * (distances[:, :1] / radius) ** 3)[:, :, None]
        constant = np.zeros((len(chunk), 10, 1))
        constant[:, 0] = 1
        projection = (design @ np.linalg.solve(normal, constant))[:, :, 0] * weights
        projection /= projection.sum(axis=1, keepdims=True)
        result[:, start:start + len(chunk)] = np.einsum('nk,snkc->snc', projection, endpoints[:, neighbors])

    gray = grid[:, 0] == grid[:, 2]
    gray_codes = np.linspace(0, 1, 32)
    for layer, table in enumerate(tables):
        delta = np.interp(grid[gray, 0], gray_codes, table[::1057].mean(axis=1))
        result[layer, gray] = delta[:, None]
    return result


def build(references, output, inputs=None, peak_references=None):
    folder = Path(__file__).resolve().parent
    calibration = json.loads((folder / 'strong-whites-calibration.json').read_text())
    acquisition = FrozenSet(references)
    responses = [(0., np.zeros((32**3, 3)))]
    diagonal = np.arange(32) * 1057
    neutral_cubes = []
    upper_pairs = []
    measured = {amount: [] for amount in calibration['strengths']}
    for scene in calibration['chartContexts']:
        neutral = cube(acquisition, scene + '-neutral')
        neutral_cubes.append(neutral)
        gray = encode(neutral[diagonal].mean(axis=1))
        displacements = {}
        for amount in calibration['strengths']:
            adjusted = cube(acquisition, f'{scene}-Whites2012-{amount}')
            displacement = (encode(adjusted[diagonal].mean(axis=1)) - gray).mean()
            displacements[amount] = displacement
            delta = adjusted - neutral
            measured[amount].append(delta.copy())
            # ICC rounding of a neutral patch is not an authored color cast.
            delta[diagonal] = delta[diagonal].mean(axis=1, keepdims=True)
            responses.append((float(displacement), delta))
        upper_pairs.append((displacements[75], displacements[100]))
    if (array_digest(np.array(neutral_cubes)) != calibration['neutralSHA256']
            or array_digest(np.array(list(measured.values()))) != calibration['cubeSHA256']):
        raise ValueError('Calibration pixels do not match the registered response measurements')
    responses.sort(key=lambda row: row[0])
    knots = np.array([q for q, _ in responses])
    if not np.isfinite(knots).all() or not np.all(np.diff(knots) > 0):
        raise ValueError('Expected distinct, increasing measured displacements')

    scenes = calibration['scenes']
    if inputs is not None:
        verify_spatial_measurements(calibration, inputs, peak_references, neutral_cubes[0][diagonal].mean(axis=1))
    summaries = np.array([scene['encodedLuminance'] for scene in scenes])
    summaries[:, 1:] -= summaries[:, :1]
    target = np.array([scene['grayDisplacement75'] for scene in scenes])
    distance = (calibration['meanWeight'] * (summaries[:, None, 0] - summaries[None, :, 0])**2
                + np.mean((summaries[:, None, 1:] - summaries[None, :, 1:])**2, axis=-1))
    inverse_width = .5 / calibration['distributionWidth']**2
    kernel = np.exp(-distance * inverse_width)
    coefficient = np.linalg.solve(kernel + calibration['ridge'] * np.eye(len(scenes)),
        target - calibration['uniformSlope'] * (1 - summaries[:, 0]))

    chart_positions, chart_tables = pack_response_axis(knots, [t for _, t in responses], neutral_cubes[0])
    positions, tables = list(chart_positions), list(chart_tables)
    by_source = {scene['sourceSHA256']: scene['grayDisplacement75'] for scene in scenes}
    ramps = [calibration['surroundRamp'], calibration['darkRamp']]
    for ramp in ramps:
        table, position = extend_with_gray_ramp(neutral_cubes[0], responses[-1][1], diagonal, ramp)
        positions.append(position)
        tables.append(table)
        upper_pairs.append((by_source[ramp['references'][0]['sourceSHA256']], position))
    field = calibration['darkField75']
    table, position = extend_to_dark_field(neutral_cubes[0], responses[-1][1], diagonal, ramps, field)
    positions.append(position)
    tables.append(table)
    if not np.all(np.diff(positions) > 0):
        raise ValueError('Expected strictly increasing response positions')
    # Every original gray location lands on a node. Store two half-floats per ordered color.
    dimension, row_width = 63, 256
    endpoints = ordered_endpoints(tables, dimension)
    rows_per_layer = (endpoints.shape[1] + row_width - 1) // row_width
    atlas = np.zeros((len(tables), rows_per_layer * row_width, 2), dtype='<f2')
    atlas[:, :endpoints.shape[1]] = endpoints
    atlas = atlas.reshape(-1, row_width, 2)[::-1]
    # If x and y are the +75 and +100 gray displacements, fit
    # y (1 + cx + dx²) = ax + bx². The gain is finite at zero.
    x75, y100 = np.array(upper_pairs).T
    terms = np.column_stack((x75, x75**2, -x75 * y100, -x75**2 * y100))
    upper_curve = np.linalg.lstsq(terms, y100, rcond=None)[0]
    a, b, c, d = upper_curve
    # The derivative has numerator a + 2bx + (bc - ad)x². Its minimum
    # over the atlas is at an endpoint when concave, and at zero otherwise.
    maximum = positions[-1]
    if (not np.isfinite(upper_curve).all() or np.any(upper_curve <= 0)
            or a + 2 * b * maximum + (b * c - a * d) * maximum**2 <= 0):
        raise ValueError('The +100 Whites displacement must increase across the atlas')
    if not np.isfinite(atlas).all():
        raise ValueError('The strong Whites atlas cannot be represented in half precision')
    peak_inputs = np.array([gray['inputLinearP3'] for gray in calibration['peakGray']])
    peak_outputs = np.array([gray['outputLinearP3'] for gray in calibration['peakGray']])
    if (peak_inputs.shape != (5,) or not np.all((0 < peak_inputs) & (peak_inputs < peak_outputs))
            or not np.all(peak_outputs <= 1)):
        raise ValueError('Invalid uniform-gray white points')
    x, y = encode(peak_inputs), encode(peak_outputs)
    peak_shoulder = float(np.median(x * (1 - y) / (y * (1 - x))))
    histograms = np.array([scene['luminanceHistogram'] for scene in scenes])
    if histograms.shape != (len(scenes), 16) or np.any(histograms < 0) or not np.allclose(histograms.sum(axis=1), 1):
        raise ValueError('Invalid calibration luminance histograms')
    # Eleven RGB texels per scene: 14 distribution descriptors, their RBF coefficient,
    # 16 square-root histogram probabilities, the measured +75 displacement and padding.
    rows = np.column_stack((summaries, coefficient, np.sqrt(histograms), target, np.zeros(len(scenes))))
    # Only the gray-field observation constrains this extension. It supplies a
    # local histogram anchor and does not participate in the global scene fit.
    level = encode(field['inputLinearP3'])
    gray = np.arange(dimension)
    gray_index = gray * (gray + 1) * (gray + 2) // 6 + gray * (gray + 1) // 2 + gray
    represented = field['inputLinearP3'] + np.interp(level, gray / (dimension - 1), endpoints[-1, gray_index, 0])
    if abs(represented - field['outputLinearP3']) > .0001:
        raise ValueError('The packed extension misses the registered dark field')
    probability = coarse_histogram(np.maximum(1 - abs(np.arange(128) - level*127), 0))
    rows = np.vstack((rows, np.r_[np.zeros(15), np.sqrt(probability), positions[-1], 0]))
    metadata = dict(dimension=dimension, rowWidth=row_width, displacements=positions,
        upperCurve=upper_curve.tolist(),
        histogramExponent=calibration['distributionGuide']['histogramExponent'],
        blurScale=calibration['distributionGuide']['blurSigmaPerLongEdge'],
        minimumPeak=float(peak_inputs.min()), peakShoulder=peak_shoulder,
        uniformSlope=calibration['uniformSlope'], meanWeight=calibration['meanWeight'], inverseWidth=inverse_width,
        amountLaw=calibration['amountLaw'], distributions=rows.tolist())
    header = json.dumps(metadata, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()
    payload = b'BRWH0008' + struct.pack('<I', len(header)) + header + atlas.tobytes()
    # compress.swift also verifies the lossless round trip.
    with tempfile.TemporaryDirectory() as work:
        raw = Path(work) / 'strong-whites.bin'
        raw.write_bytes(payload)
        subprocess.run(['xcrun', 'swift', str(folder/'compress.swift'), str(raw), str(output)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('references', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--distribution-inputs', type=Path, help='registered source TIFFs decoded to linear P3')
    parser.add_argument('--peak-references', type=Path, help='registered Lightroom gray fields at +100')
    args = parser.parse_args()
    if bool(args.distribution_inputs) != bool(args.peak_references):
        parser.error('Supply both verification directories together')
    if args.output.exists():
        parser.error('Output already exists')
    build(args.references, args.output, args.distribution_inputs, args.peak_references)
