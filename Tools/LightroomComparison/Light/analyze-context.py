"""Compare Adobe response to identical ramps under different backgrounds.

The result tests a pointwise hypothesis. It cannot distinguish a local operation
from a whole-image statistic, and does not infer a convolution kernel.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('references', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
assert not args.output.exists(), 'Do not overwrite evidence'
root = args.references
refs = {r['id']: r for r in json.loads((root/'references.json').read_text())['references']}
decoded = {Path(r['input']).stem: r for r in json.loads((root/'decoded/manifest.json').read_text())}
evidence = {}

def read(identity):
  reference = root/refs[identity]['reference']
  with reference.open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
  assert digest == refs[identity]['referenceSHA256'] == decoded[identity]['sha256']
  data = (root/'decoded'/(identity+'.rgba32f')).read_bytes()
  pixels = np.frombuffer(data, '<f4').reshape(256, 1024, 4)
  assert np.isfinite(pixels).all() and np.max(abs(pixels[..., 3]-1)) < 1e-6
  evidence[identity] = dict(referenceSHA256=digest, decodedSHA256=hashlib.sha256(data).hexdigest())
  return pixels[..., :3].astype(float)

neutral = {name: read(f'context-{name}-neutral') for name in ['ramp', 'dark', 'light', 'midgray']}
for name in ['dark', 'light']:
  assert np.array_equal(neutral[name][128], neutral['ramp'][128]), 'The tested ramp inputs differ'
records = []
for key in ['Whites2012', 'Blacks2012']:
  for amount in [-25, 25]:
    response = {name: read(f'context-{name}-{key}-{amount}') - neutral[name] for name in neutral}
    records.append(dict(parameter=key, amount=amount,
      centralRampMaximumResponseDifference={name:
        float(np.max(abs(response[name][128] - response['ramp'][128]))) for name in ['dark', 'light']},
      uniformMidgrayResponse=response['midgray'][128, 512].tolist(),
      nearestRampMidgrayResponse=response['ramp'][128, 512].tolist()))
args.output.write_text(json.dumps(dict(
  measurement='Float32 linear Display-P3 RGB; white=1; identical central ramp at row 128',
  caution='Uniform midgray and nearest ramp midgray have slightly different input values; only the central ramps are exact input matches',
  interpretation='Context dependence falsifies a fixed pointwise transform; local versus global adaptation is unresolved',
  cases=records, references=evidence), indent=2)+'\n')
print('Recorded', len(records), 'signed controls and', len(evidence), 'reference hashes')
