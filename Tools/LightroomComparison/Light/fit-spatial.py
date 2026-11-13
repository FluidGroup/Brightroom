"""Fit spatial H/S using only registered synthetic grayscale scenes.

Photographs, A10, and the independent color scene are never loaded. Five entire
synthetic scenes select the model's domain, width, and ridge penalty. Reported
validation is model-selection evidence, not an independent compatibility pass.
"""
import argparse
import json
from pathlib import Path
import platform
import numpy as np
import scipy
from scipy.cluster.vq import kmeans2
from scipy.ndimage import gaussian_filter
from scipy.spatial.distance import cdist
from adaptive_data import FrozenSet

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('research', type=Path)
parser.add_argument('model', type=Path)
parser.add_argument('report', type=Path)
args = parser.parse_args()
assert not args.model.exists() and not args.report.exists(), 'Do not overwrite evidence'
spatial = FrozenSet(args.research / 'adaptive-002')
gray = FrozenSet(args.research / 'adaptive-calibration-001')
scenes = FrozenSet(args.research / 'adaptive-scenes-001')
names = ['ramp', 'permuted', 'near-dark', 'near-light', 'dark', 'light',
         'low-ramp', 'mid-ramp', 'high-ramp', 'flat-10', 'flat-25', 'flat-50', 'flat-75', 'flat-90']
names += [f'scene-{i:02d}' for i in range(16)]
controls = [('Highlights2012', -50), ('Highlights2012', 50), ('Shadows2012', -50), ('Shadows2012', 50)]
validation = ['mid-ramp', 'scene-02', 'scene-07', 'scene-08', 'scene-13']
training = [name for name in names if name not in validation]


def load(name, key):
    if name.startswith('scene-'):
        return scenes.read(f'scene-fit-{name}-{key}')[..., :3].mean(2).astype(float)
    root, prefix = (spatial, 'adaptive-') if name in names[:6] else (gray, 'adaptcal-')
    return root.read(f'{prefix}{name}-{key}')[..., :3].mean(2).astype(float)


def encode(x):
    return np.where(x <= .0031308, 12.92 * x, 1.055 * np.maximum(x, 0) ** (1 / 2.4) - .055)


def decode(x):
    return np.where(x <= .04045, x / 12.92, ((np.maximum(x, 0) + .055) / 1.055) ** 2.4)


def logit(x):
    return np.log(np.clip(x, 1e-5, 1 - 1e-5) / np.clip(1 - x, 1e-5, 1 - 1e-5))


def features(x, mode):
    value = encode(x) if mode == 'encoded' else np.log(np.maximum(x, 1e-4)) / 9.3 + 1
    scale = max(value.shape) / 1024
    blur = [gaussian_filter(value, radius * scale, mode='nearest') for radius in [4, 16, 64, 256]]
    deviation = [np.sqrt(np.maximum(gaussian_filter(value * value, radius * scale, mode='nearest') - mean * mean, 0))
                 for radius, mean in zip([16, 64], blur[1:3])]
    return np.stack([value] + blur + deviation +
                    [np.full_like(value, value.mean()), np.full_like(value, value.std())], axis=-1)


sources = {name: load(name, 'neutral') for name in names}
targets = {name: np.stack([load(name, f'{key}-{amount}') for key, amount in controls], axis=-1) for name in names}
options = []
for mode in ['encoded', 'log']:
    measurements = {name: features(x, mode)[::8, ::8].reshape(-1, 9) for name, x in sources.items()}
    a = np.concatenate([measurements[name] for name in training])
    mean = a.mean(0)
    scale = np.maximum(a.std(0), .04)
    z = (a - mean) / scale
    centers, _ = kmeans2(z, 192, minit='++', seed=19, iter=20)
    for output in ['encoded', 'logit']:
        transformed = {name: ((encode(targets[name]) - encode(sources[name])[..., None]) if output == 'encoded'
                       else (logit(targets[name]) - logit(sources[name])[..., None]))[::8, ::8].reshape(-1, 4) for name in names}
        b = np.concatenate([transformed[name] for name in training])
        for width in [1, 2, 3]:
            design = np.exp(-cdist(z, centers, 'sqeuclidean') / (2 * width ** 2))
            for ridge in [.001, .1, 1]:
                weights = np.linalg.solve(design.T @ design + np.eye(len(centers)) * ridge, design.T @ b)
                metrics = {}
                for name in names:
                    response = np.exp(-cdist((measurements[name] - mean) / scale, centers, 'sqeuclidean') / (2 * width ** 2)) @ weights
                    x = sources[name][::8, ::8].ravel()
                    y = targets[name][::8, ::8].reshape(-1, 4)
                    if name.startswith('flat-'):
                        response *= 0  # independently observed uniform-field neutrality
                    response[:, [0, 2]] = np.minimum(response[:, [0, 2]], 0)
                    response[:, [1, 3]] = np.maximum(response[:, [1, 3]], 0)
                    if output == 'encoded':
                        prediction = decode(np.clip(encode(x)[:, None] + response, 0, 1))
                    else:
                        prediction = 1 / (1 + np.exp(-np.clip(logit(x)[:, None] + response, -30, 30)))
                    error = abs(prediction - y)
                    metrics[name] = dict(rms=np.sqrt(np.mean(error * error, 0)).tolist(),
                                         p95=np.quantile(error, .95, axis=0).tolist())
                score = float(np.mean([metrics[name]['rms'] for name in validation]) +
                              .1 * np.mean([metrics[name]['rms'] for name in training]))
                options.append(dict(mode=mode, output=output, width=width, ridge=ridge, score=score,
                    metrics=metrics, mean=mean.tolist(), scale=scale.tolist(), centers=centers.tolist(), weights=weights.tolist()))
    print('Completed', mode, flush=True)
best = min(options, key=lambda item: item['score'])
# The renderer implements this domain pair. A future winning model with a
# different representation requires an explicit implementation change.
assert (best['mode'], best['output']) == ('log', 'encoded')
model = {key: best[key] for key in ['mean', 'scale', 'centers', 'weights', 'width']}
model['amountKnots'] = [0, 10, 25, 50, 100]
model['amountScales'] = []
x = spatial.read('adaptive-ramp-neutral')[128, :, 0]
for key, direction in [('Highlights2012', -1), ('Highlights2012', 1), ('Shadows2012', -1), ('Shadows2012', 1)]:
    base = encode(spatial.read(f'adaptive-ramp-{key}-{50 * direction}')[128, :, 0]) - encode(x)
    scales = [0]
    for amount in [10, 25, 50, 100]:
        root, prefix = (spatial, 'adaptive-') if amount == 50 else (gray, 'adaptcal-')
        delta = encode(root.read(f'{prefix}ramp-{key}-{amount * direction}')[128, :, 0]) - encode(x)
        scales.append(float(np.dot(base, delta) / np.dot(base, base)))
    model['amountScales'].append(scales)
args.model.write_text(json.dumps(model, separators=(',', ':')) + '\n')
report = dict(purpose=__doc__, training=training, modelSelection=validation,
    environment=dict(python=platform.python_version(), numpy=np.__version__, scipy=scipy.__version__),
    selected={key: best[key] for key in ['mode', 'output', 'width', 'ridge', 'score', 'metrics']},
    candidates=[{key: item[key] for key in ['mode', 'output', 'width', 'ridge', 'score']} for item in options],
    references=[item for root in [spatial, gray, scenes] for item in root.evidence.values()])
args.report.write_text(json.dumps(report, indent=2) + '\n')
print('Selected', best['mode'], best['output'], best['width'], best['ridge'], 'score', best['score'])
