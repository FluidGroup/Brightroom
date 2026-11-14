"""Refit the spatial gain between Highlights −50 and −100 from matched GPU and Lightroom samples."""
import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.optimize import minimize


@dataclass
class Sample:
    """One source with two signed error vectors and one-sided GPU sensitivities per pixel."""

    source: str
    distribution: np.ndarray
    response_error: np.ndarray
    interval_error: np.ndarray
    current_loss: np.ndarray
    more_gain: np.ndarray
    less_gain: np.ndarray

    def errors(self, coefficients, stride):
        gain = np.clip(self.distribution[::stride] @ coefficients, -1, 2)
        derivative = np.where(gain[:, None] >= 0, self.more_gain[::stride], self.less_gain[::stride])
        change = derivative * gain[:, None]
        return np.array([
            np.quantile(np.max(np.abs(error[::stride] + change), axis=1), .95, method='inverted_cdf')
            for error in (self.response_error, self.interval_error)
        ])


def load_samples(manifest_path):
    manifest = json.loads(manifest_path.read_text())
    probe = manifest['probe']
    if manifest['control'] != 'Highlights2012' or not 0 < probe < 1:
        raise ValueError('Expected a negative Highlights interval with a positive sensitivity probe')
    samples = []
    sources = set()
    for entry in manifest['cases']:
        path = manifest_path.parent / entry['file']
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != entry['sha256'] or entry['inputSHA256'] in sources:
            raise ValueError(f"Changed or duplicated calibration source {entry['source']}")
        sources.add(entry['inputSHA256'])
        with np.load(path, allow_pickle=False) as capture:
            indices = capture['indices']
            count = len(indices)
            if not count or len(np.unique(indices)) != count:
                raise ValueError(f'Empty or repeated sample indices in {path}')
            values = {name: capture[name] for name in capture.files if name != 'indices'}
            if any(v.shape != (count, 3) or not np.isfinite(v).all() for v in values.values()):
                raise ValueError(f'Invalid linear RGB samples or guide statistics in {path}')
        scene, blurred, region = values['stats'].astype(float).T
        fine = 1 - np.square(blurred / np.maximum(scene, 1e-8))
        distribution = np.column_stack((np.ones(count), np.minimum(5 * scene, 1),
            np.clip(6 * fine, 0, 1), np.minimum(region / np.maximum(scene, .04), 2)))
        source = values['neutral'].astype(float)
        half = values['half'].astype(float)
        full = values['full'].astype(float)
        reference = values['referenceFull'].astype(float) - values['referenceNeutral'].astype(float)
        response_error = full - (source + reference)
        weaker = source + (values['referenceHalf'] - values['referenceHalfNeutral'])
        samples.append(Sample(entry['source'], distribution, response_error, response_error - (half - weaker),
            half - full, (values['darker'] - full) / probe, (full - values['lighter']) / probe))
    if len(samples) < 2:
        raise ValueError('At least two distinct calibration inputs are required')
    return samples


def fit(samples):
    """Give each source equal weight and penalize regressions in either measured interval."""
    zero = np.zeros(4)
    baseline = [s.errors(zero, 3) for s in samples]

    def objective(coefficients):
        delta = np.array([s.errors(coefficients, 3) - original for s, original in zip(samples, baseline)])
        regression = np.maximum(delta, 0)
        return (delta + 1.7 * regression).mean() + .3 * regression.max() + .00075 * np.linalg.norm(coefficients)

    # Linear fits of the two endpoints seed the search on the measured GPU sensitivities.
    starts = [zero]
    for fraction in (0, .5, 1):
        gram = []
        rhs = []
        for sample in samples:
            loss = sample.current_loss
            magnitude = np.sum(loss * loss, axis=1)
            normalization = len(loss) * max(magnitude.mean(), 1e-5)
            error = (1 - fraction) * sample.response_error + fraction * sample.interval_error
            basis = sample.distribution
            gram.append(basis.T @ (basis * magnitude[:, None]) / normalization)
            rhs.append(basis.T @ np.sum(loss * error, axis=1) / normalization)
        starts.append(np.linalg.solve(np.mean(gram, axis=0) + .015 * np.eye(4), np.mean(rhs, axis=0)))
    rng = np.random.default_rng(41)
    starts.extend(rng.normal(0, [.22, .40, .45, .30], size=(500, 4)))
    results = []
    for initial in sorted(starts, key=objective)[:5]:
        simplex = np.vstack([initial, initial + np.eye(4) * .08])
        results.append(minimize(objective, initial, method='Nelder-Mead', options={
            'initial_simplex': simplex, 'maxiter': 170, 'xatol': .0007, 'fatol': .000005,
        }))
    return min(results, key=lambda r: r.fun).x


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path, help='Integrity-checked sample captures from registered −50 and −100 pairs')
    parser.add_argument('--leave-one-out', action='store_true', help='Refit while withholding each complete input')
    args = parser.parse_args()
    samples = load_samples(args.manifest)
    weights = fit(samples)
    result = {'coefficients': weights.tolist(), 'sources': [s.source for s in samples]}
    if args.leave_one_out:
        held = {}
        for index, source in enumerate(samples):
            other = samples[:index] + samples[index + 1:]
            fitted = fit(other)
            held[source.source] = (source.errors(fitted, 1) - source.errors(np.zeros(4), 1)).tolist()
        result['heldResponseAndIntervalP95Change'] = held
    print(json.dumps(result, indent=2))
