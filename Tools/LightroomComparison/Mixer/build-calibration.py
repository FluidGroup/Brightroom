"""Reproduce the measured Color Mixer model from frozen analytic references.

Only single-band +/-50 and uniform-band response cases train the model. A10,
photographs, and intermediate or combined parameter holdouts are never read.
Run decode.swift before this script; the decoded image hashes must match the
registered Adobe exports. The resulting binary is compressed by model-codec.swift.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('independent', type=Path)
parser.add_argument('uniform', type=Path)
parser.add_argument('output', type=Path, help='New uncompressed .bin file')
parser.add_argument('manifest', type=Path)
args = parser.parse_args()
assert not args.output.exists() and not args.manifest.exists()
bands = ['Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta']
axes = ['Hue', 'Saturation', 'Luminance']
knots = np.arange(-100, 101, 25)
records = []


def digest(path):
  with path.open('rb') as stream:
    return hashlib.file_digest(stream, 'sha256').hexdigest()


def reader(root):
  references = {r['id']:r for r in json.loads((root/'references.json').read_text())['references']}
  decoded = {Path(r['input']).stem:r for r in json.loads((root/'decoded/manifest.json').read_text())}
  def load(name):
    identity = 'adjust-chart-' + name
    ref = references[identity]
    source = root/ref['reference']
    assert digest(source) == ref['referenceSHA256'] == decoded[identity]['sha256']
    path = root/'decoded'/(identity+'.rgba32f')
    pixels = np.fromfile(path, '<f4').reshape(256, 1024, 4)
    assert np.isfinite(pixels).all() and np.max(abs(pixels[...,3]-1)) < 1e-6
    records.append(dict(set=root.name, id=identity, referenceSHA256=ref['referenceSHA256'],
      decodedSHA256=digest(path)))
    return pixels[128::4,:,:3].reshape(-1,3).astype(np.float64)
  return load


single = reader(args.independent)
uniform = reader(args.uniform)
base = single('neutral')
uniform_base = uniform('neutral')
responses = np.array([[uniform(f'uniform-{axis}-{v}') - uniform_base if v else np.zeros_like(base)
  for v in knots] for axis in axes])
count = len(base)
indices = np.arange(count)


def interpolate(axis, amount):
  position = np.clip((amount + 100) / 25, 0, 8)
  lower = np.minimum(np.floor(position).astype(int), 7)
  fraction = position - lower
  return (responses[axis, lower, indices] * (1-fraction[:,None])
    + responses[axis, lower+1, indices] * fraction[:,None])


weights = np.zeros((3,8,2,count))
for axis, name in enumerate(axes):
  for band, color in enumerate(bands):
    for sign_index, sign in enumerate([-1,1]):
      target = single(f'{name}Adjustment{color}-{sign*50}') - base
      best = np.full(count, np.inf)
      # A common strength curve and a scalar selection weight, rather than
      # adding independent image deltas after each overlapping band.
      for weight in np.linspace(0,1,401):
        prediction = interpolate(axis, np.full(count, sign*50*weight))
        error = ((prediction-target)**2).sum(axis=1)
        better = error < best
        weights[axis,band,sign_index,better] = weight
        best[better] = error[better]


def resample(values, coordinates):
  """Resample the measured encoded-P3 lattice to the smaller stored lattice."""
  # Follow the runtime's linear-pixel -> encoded-coordinate route. Keeping this
  # round trip explicit also fixes Float16 rounding at the few midpoint ties.
  linear = np.where(coordinates <= .04045, coordinates/12.92,
    ((coordinates+.055)/1.055)**2.4)
  encoded = np.where(linear <= .0031308, linear*12.92,
    1.055*np.maximum(linear,0)**(1/2.4)-.055)
  coordinate = encoded.clip(0,1)*31
  lower = np.floor(coordinate).astype(int)
  upper = np.minimum(lower+1,31)
  fraction = coordinate-lower
  result = np.zeros((len(coordinate),)+values.shape[1:])
  for b in range(2):
    for g in range(2):
      for r in range(2):
        corner = np.where([r,g,b],upper,lower)
        weight = np.prod(np.where([r,g,b],fraction,1-fraction),axis=1)
        sample = values[corner[:,0]+32*corner[:,1]+1024*corner[:,2]]
        result += sample*weight.reshape((-1,)+(1,)*(sample.ndim-1))
  return result


dimension = 24
coordinates = np.array([(r,g,b) for b in range(dimension)
  for g in range(dimension) for r in range(dimension)])/(dimension-1)
weights = resample(weights.transpose(3,0,1,2),coordinates).transpose(1,2,3,0).astype('<f2')
responses = resample(responses.transpose(2,0,1,3),coordinates).transpose(1,2,0,3).astype('<f2')
for i in range(dimension):
  node = i+dimension*i+dimension*dimension*i
  weights[...,node] = 0
  responses[:,:,node,:] = 0
blob = b'BRCM0001'+struct.pack('<I',dimension)+weights.tobytes()+responses.tobytes()
args.output.write_bytes(blob)
args.manifest.write_text(json.dumps(dict(
  format='BRCM0001 + UInt32 dimension + Float16 weights[HSL,band,sign,node] + responses[HSL,knot,node,RGB]',
  dimension=dimension, sourceDimension=32, responseKnots=knots.tolist(),
  domain='encoded Display-P3; response deltas in linear Display-P3',
  runtime='signed selection weights, piecewise linear parameter response, L/S/H, tetrahedral RGB interpolation',
  limits='Experimental SDR approximation; range extensions are not measured Adobe HDR behavior',
  outputSHA256=digest(args.output), sourceSHA256=digest(Path(__file__)), references=records),indent=2)+'\n')
print(digest(args.output), len(blob), 'bytes', len(records), 'references')
