"""Experimental pointwise Whites, Blacks and Saturation model for the host adapter.

Highlights/Shadows are deliberately excluded: a chart-only model failed the
photographic validation. No A10 or photo response enters this model.
"""
import hashlib
import json
from pathlib import Path
import numpy as np


class PointModel:
  """Frozen chart responses; positive Whites has a known photographic failure."""

  def __init__(self, coarse, fine, keys=None):
    self.knots = np.array([-100,-50,-25,-10,0,10,25,50,100])
    self.keys = list(keys) if keys is not None else ['Whites2012','Blacks2012','Saturation']
    if not self.keys or not set(self.keys) <= {'Whites2012','Blacks2012','Saturation'}:
      raise ValueError(f'Unsupported calibration keys: {self.keys}')
    self.evidence = []
    self.responses = {}
    roots = [Path(coarse),Path(fine)]
    references = [{r['id']:r for r in json.loads((root/'references.json').read_text())['references']}
      for root in roots]
    decoded = [{Path(r['input']).stem:r for r in json.loads((root/'decoded/manifest.json').read_text())}
      for root in roots]

    def load(index, name):
      root = roots[index]
      identity = 'adjust-chart-'+name
      ref = references[index][identity]
      path = root/ref['reference']
      with path.open('rb') as stream:
        if not hashlib.file_digest(stream,'sha256').hexdigest() == ref['referenceSHA256'] == decoded[index][identity]['sha256']:
          raise ValueError(f'Changed or stale point reference: {path}')
      data = (root/'decoded'/(identity+'.rgba32f')).read_bytes()
      pixels = np.frombuffer(data,'<f4').reshape(256,1024,4)
      if not np.isfinite(pixels).all() or np.max(abs(pixels[...,3]-1)) >= 1e-6:
        raise ValueError(f'Nonfinite or nonopaque point samples: {identity}')
      self.evidence.append(dict(set=root.name,id=identity,referenceSHA256=ref['referenceSHA256'],
        decodedSHA256=hashlib.sha256(data).hexdigest()))
      return pixels[128::4,:,:3].reshape(-1,3).astype(float)

    neutral = [load(i,'neutral') for i in range(2)]
    for key in self.keys:
      responses = []
      for amount in self.knots:
        if amount == 0:
          responses.append(np.zeros_like(neutral[0]))
        else:
          index = 0 if abs(amount) >= 50 else 1
          responses.append(load(index,f'{key}-{amount}')-neutral[index])
      self.responses[key] = np.array(responses)

  def compile(self, settings):
    tables = []
    for key in self.keys:
      amount = float(settings.get(key,0))
      if not np.isfinite(amount) or not -100 <= amount <= 100:
        raise ValueError(f'Point amount must be finite and within [-100, 100]: {key}')
      lower = int(np.clip(np.searchsorted(self.knots,amount,side='right')-1,0,7))
      fraction = (amount-self.knots[lower])/(self.knots[lower+1]-self.knots[lower])
      response = self.responses[key][lower]*(1-fraction)+self.responses[key][lower+1]*fraction
      # The neutral diagonal is a real tonal response for Whites/Blacks. Only
      # global Saturation must leave achromatic pixels unchanged.
      if key == 'Saturation':
        response[[i+32*i+1024*i for i in range(32)]] = 0
      rgba = np.column_stack([response,np.ones(len(response))]).astype('<f4')
      tables.append(rgba.reshape(1024,32,4)[::-1].tobytes())
    return b''.join(tables)
