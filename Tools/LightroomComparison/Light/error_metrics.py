"""RGB error statistics using the frozen compare.swift percentile convention.

Callers own ICC conversion, image identity, shape and alpha validation. This
module only compares finite RGB samples in the same linear space. Values use
output white = 1 and are not perceptual Delta E. In particular, a numerical
prediction is not evidence of a public-feature render.
"""
import math

import numpy as np


def nearest_rank(values, probability):
    """Return sorted[ceil(n * probability) - 1], with no interpolation."""
    values = np.asarray(values).reshape(-1)
    if not 0 < probability <= 1 or not values.size or not np.isfinite(values).all():
        raise ValueError('Percentiles require nonempty finite values and 0 < p <= 1')
    index = math.ceil(values.size * probability) - 1
    return float(np.partition(values, index)[index])


def rgb_error(candidate, reference):
    """Compare matching RGB arrays with Double deltas and Float pixel maxima.

    Those precision boundaries match compare.swift when the inputs come from
    its Float32 decoding space. Numerical fit outputs may have higher input
    precision; callers must label that distinction in their reports.
    """
    candidate = np.asarray(candidate, dtype=np.float64)
    reference = np.asarray(reference, dtype=np.float64)
    if candidate.shape != reference.shape or candidate.ndim < 2 or candidate.shape[-1] != 3:
        raise ValueError('Expected matching arrays of RGB samples')
    if not candidate.size or not np.isfinite(candidate).all() or not np.isfinite(reference).all():
        raise ValueError('Cannot measure empty or nonfinite RGB samples')
    difference = (candidate - reference).reshape(-1, 3)
    maximum = np.max(np.abs(difference), axis=1).astype(np.float32)
    if not np.isfinite(maximum).all():
        raise ValueError('RGB difference exceeds finite Float32 range')
    return dict(
        pixels=len(difference),
        rgbRMS=float(np.sqrt(np.mean(difference * difference))),
        p50MaxChannel=nearest_rank(maximum, .5),
        p95MaxChannel=nearest_rank(maximum, .95),
        p99MaxChannel=nearest_rank(maximum, .99),
        maxAbsolute=float(np.max(np.abs(difference))),
        channelBias=np.mean(difference, axis=0).tolist(),
    )
