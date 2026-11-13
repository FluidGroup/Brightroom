"""Pack the negative Highlights response gain over global mean and smoothed log-luminance deviation."""
import argparse
import json
from pathlib import Path

import numpy as np


def build(calibration, output):
    model = json.loads(calibration.read_text())
    samples = model['samples']
    scenes = np.array([[row['mean'], row['localActivity']] for row in samples])
    targets = np.array([row['logGain'] for row in samples])
    if len({row['sourceSHA256'] for row in samples}) != len(samples):
        raise ValueError('Each calibration source must contribute one independent gain')
    scale = np.maximum(scenes.std(axis=0), model['minimumScale'])

    def basis(points):
        distance = ((points[:, None, :] - scenes[None, :, :]) / scale) ** 2
        return np.exp(-distance.mean(axis=2) / (2 * model['width'] ** 2))

    weights = np.linalg.solve(basis(scenes) + model['ridge'] * np.eye(len(scenes)), targets)
    activity, mean = np.mgrid[:33, :65]
    points = np.column_stack((mean.ravel(), activity.ravel())) / 64
    gains = np.exp(model['shrink'] * (basis(points) @ weights)).reshape(activity.shape)
    if not np.all(np.isfinite(gains) & (gains > 0)):
        raise ValueError('Invalid Highlights response gain')
    # Core Image reads bitmap scanlines from the top. The kernel measures activity upward.
    with output.open('xb') as stream:
        stream.write(gains[::-1].astype('<f4').tobytes())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    build(Path(__file__).with_name('highlights-strength-calibration.json'), args.output)
