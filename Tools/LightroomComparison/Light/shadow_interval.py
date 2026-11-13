"""Estimate the ProPhoto log-odds bounds from registered pairs of Shadows strengths."""
import numpy as np
from scipy.optimize import least_squares

from adaptive_data import P3_TO_ROMM


ROMM_TO_P3 = np.linalg.inv(P3_TO_ROMM)


def extrema(rgb, source):
    """Follow the channels that defined the original hue, including when they meet."""
    indices = np.stack((source.argmin(axis=1), source.argmax(axis=1)), axis=1)
    return np.take_along_axis(rgb, indices, axis=1)


def fit_range(charts, amounts):
    """Fit bounds of a log-odds coordinate. Each input chart has equal weight."""
    intervals = []
    for levels in charts:
        src = levels[0] @ P3_TO_ROMM.T
        start = extrema(src, src)
        extent = np.ptp(src, axis=1, keepdims=True)
        position = (src - start[:, :1]) / np.maximum(extent, 1e-9)
        for a, b in zip(amounts, amounts[1:]):
            end = extrema(levels[a] @ P3_TO_ROMM.T, src)
            intervals.append((start, end, position, b / a, levels[b]))

    def residuals(log_bounds):
        black_room, white_room = np.exp(log_bounds)
        white = 1 + white_room

        def odds(rgb):
            return np.log(np.maximum(rgb + black_room, 1e-9) / np.maximum(white - rgb, 1e-9))

        def linear(coordinate):
            return (white + black_room) / (1 + np.exp(-np.clip(coordinate, -60, 60))) - black_room

        residuals = []
        for start, end, position, strength, target in intervals:
            first, second = odds(start), odds(end)
            final = end + (linear(first + strength * (second - first)) - linear(second))
            rgb = final[:, :1] + position * (final[:, 1:2] - final[:, :1])
            residuals.append(((rgb @ ROMM_TO_P3.T - target) * np.sqrt(32768 / len(target))).ravel())
        return np.concatenate(residuals)

    result = least_squares(residuals, np.log([.02, .1]), loss='soft_l1', f_scale=.002, max_nfev=40)
    if not result.success:
        raise ValueError(result.message)
    return np.exp(result.x)
