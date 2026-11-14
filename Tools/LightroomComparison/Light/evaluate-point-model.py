"""Falsify a pointwise Light model on a photograph without fitting that photograph.

Requires decoded chart arrays and stride-8 photo arrays made by the adjacent
Swift decoder. It predicts each independent photo parameter using only the
chart's +/-50 response. This is a diagnostic, not a production implementation.
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
assert not args.output.exists()
root = args.references
cases = json.loads((root/'cases.json').read_text())['cases']
refs = {r['id']:r for r in json.loads((root/'references.json').read_text())['references']}
consumed = {}


def read(identity, folder):
  path = root/folder/(identity+'.rgba32f')
  manifest = json.loads((root/folder/'manifest.json').read_text())
  item = next(r for r in manifest if Path(r['input']).stem == identity)
  assert item['sha256'] == refs[identity]['referenceSHA256']
  with (root/refs[identity]['reference']).open('rb') as stream:
    assert hashlib.file_digest(stream,'sha256').hexdigest() == item['sha256']
  consumed[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
  pixels = np.fromfile(path,'<f4').reshape(item['height'],item['width'],4)
  assert np.isfinite(pixels).all() and np.max(abs(pixels[...,3]-1)) < 1e-6
  return pixels[...,:3].astype(float)


chart = read('adjust-chart-neutral','decoded')
photo = read('adjust-photo-neutral','photo-samples').reshape(-1,3)
coordinate = np.where(photo<=.0031308,12.92*photo,
  1.055*np.maximum(photo,0)**(1/2.4)-.055).clip(0,1)*31
lower = np.floor(coordinate).astype(int)
upper = np.minimum(lower+1,31)
fraction = coordinate-lower
records = []
for case in cases:
  if case['kind'] != 'photo' or case['group'] != 'light' or len(case['parameters']) != 1:
    continue
  key, amount = next(iter(case['parameters'].items()))
  strength = 50 if amount > 0 else -50
  adjusted = read(f'adjust-chart-{key}-{strength}','decoded')
  response = (adjusted-chart)[128::4].reshape(-1,3)*abs(amount/50)
  predicted = photo.copy()
  for b in range(2):
    for g in range(2):
      for r in range(2):
        corner = np.where([r,g,b],upper,lower)
        weight = np.prod(np.where([r,g,b],fraction,1-fraction),axis=1)
        predicted += response[corner[:,0]+32*corner[:,1]+1024*corner[:,2]]*weight[:,None]
  target = read(case['id'],'photo-samples').reshape(-1,3)
  error = np.max(abs(predicted-target),1)
  records.append(dict(id=case['id'],parameter=key,amount=amount,
    p50=float(np.quantile(error,.5)),p95=float(np.quantile(error,.95)),maximum=float(error.max()),
    adobeResponseP95=float(np.quantile(np.max(abs(target-photo),1),.95)),
    predictedResponseP95=float(np.quantile(np.max(abs(predicted-photo),1),.95))))
args.output.write_text(json.dumps(dict(
  status='Diagnostic: pointwise chart response rejected for photographic Shadows',
  measurement='linear Display-P3 max-channel absolute error; stride-8 samples, not full-image percentiles',
  model='signed piecewise-linear +/-50 chart response with trilinear RGB interpolation',
  consumedSHA256=consumed,cases=records),indent=2)+'\n')
print(json.dumps(records,indent=2))
