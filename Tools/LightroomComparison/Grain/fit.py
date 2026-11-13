"""Estimate grain statistics at 20/42/70 using the A10 gray ramp and one region of sky.

Arguments are ICC-decoded .rgba32f paths in off/on order for the chart and
photograph. The 16-region evaluation grid is separate. Size, Roughness and
Amount slider curves cannot be identified from these two image pairs.
"""
import argparse
import json
import math
from pathlib import Path

import numpy as np

from measure import encoded_romm, read


def weights(sigma):
    offsets = np.arange(-8, 9)
    denominator = math.sqrt(2) * sigma
    return np.array([(math.erf((i + .5) / denominator) - math.erf((i - .5) / denominator)) / 2 for i in offsets])


def minimum(function, low, high):
    # Only one continuous parameter is fitted at each step.
    for _ in range(26):
        left, right = (2 * low + high) / 3, (low + 2 * high) / 3
        if function(left) < function(right):
            high = right
        else:
            low = left
    return (low + high) / 2


def blur(source, sigma):
    result = source
    for axis in (0, 1):
        result = sum(w * np.roll(result, i, axis) for i, w in zip(range(-8, 9), weights(sigma)) if w > 1e-8)
    return result


def noise_width(signal):
    measured = []
    for lag in range(1, 7):
        measured.append(np.mean([np.corrcoef(a[:, lag:].ravel(), a[:, :-lag].ravel())[0, 1]
                                 for a in (signal, signal.T)]))
    def loss(sigma):
        w = weights(sigma)
        autocorrelation = np.correlate(w, w, 'full')[len(w)-1:] / np.dot(w, w)
        return np.sum((autocorrelation[1:7] - measured) ** 2)
    return minimum(loss, .1, 2), measured


parser = argparse.ArgumentParser(description=__doc__)
for name in ('chart_off', 'chart_on', 'photo_off', 'photo_on', 'output'):
    parser.add_argument(name, type=Path)
args = parser.parse_args()
chart_off, c0 = read(args.chart_off)
chart_on, c1 = read(args.chart_on)
photo_off, p0 = read(args.photo_off)
photo_on, p1 = read(args.photo_on)
if chart_off.shape != chart_on.shape or photo_off.shape != photo_on.shape or \
        chart_off.shape[:2] != (256, 1024) or photo_off.shape[:2] != (4000, 6000):
    raise ValueError('Expected the registered 1024×256 chart and 6000×4000 photo pairs')
sky = np.s_[400:784, 1700:2212]
a, b = (encoded_romm(image[sky]) for image in (photo_off, photo_on))
chroma = a[..., :2] - a[..., 2:]
target = b[..., :2] - b[..., 2:]
valid = (a.min(-1) > .13) & (a.max(-1) < .87)
valid[:8] = valid[-8:] = valid[:, :8] = valid[:, -8:] = False

def edge_loss(sigma):
    return np.mean((blur(chroma, sigma)[valid] - target[valid]) ** 2)

image_sigma = minimum(edge_loss, .3, .7)
photo_signal = (b - blur(a, image_sigma))[12:-12, 12:-12, 1]
ramp = np.s_[4:56, 150:875]
chart_signal = (encoded_romm(chart_on[ramp]) - encoded_romm(chart_off[ramp]))[..., 1]
small, small_ac = noise_width(chart_signal)
large, large_ac = noise_width(photo_signal)
area_ratio = np.prod(chart_off.shape[:2]) / np.prod(photo_off.shape[:2])
scale_squared = (large**2 - small**2) / (1 - area_ratio)
floor = math.sqrt(small**2 - area_ratio * scale_squared)
small_sd, large_sd = chart_signal.std(), photo_signal.std()
power = math.log(small_sd / large_sd) / math.log(large / small)
report = dict(references=[c0, c1, p0, p1], sliders=dict(amount=20, size=42, roughness=70),
    chartBox=[150, 4, 725, 52], skyBox=[1700, 400, 512, 384], imageBlurSigma=image_sigma,
    noiseSigma=[small, large], adjacentThroughSixPixels=[small_ac, large_ac], encodedSD=[small_sd, large_sd],
    noiseSigmaFloor=floor, noiseSigmaAt24MPExcludingFloor=math.sqrt(scale_squared),
    intensityExponent=power, intensityAtUnitSigmaAndAmount100=large_sd * large**power / .2)
with args.output.open('x') as stream:
    json.dump(report, stream, indent=2, allow_nan=False)
    stream.write('\n')
