"""Freeze chart-only Whites/Blacks responses for the public parametric features.

This is a pointwise approximation. Photographs and context probes are validation
only; no adaptive or photographic correction is inferred by this builder.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import numpy as np
from point_model import PointModel

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('coarse', type=Path)
parser.add_argument('fine', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('manifest', type=Path)
args = parser.parse_args()
assert not args.output.exists() and not args.manifest.exists(), 'Do not overwrite evidence'
model = PointModel(args.coarse, args.fine, keys=['Whites2012', 'Blacks2012'])
responses = np.array([model.responses[key] for key in model.keys])
diagonal = np.arange(32) * (1 + 32 + 32 * 32)
# Neutral input must remain neutral. Remove the tiny channel disagreement from
# TIFF/ICC measurement rounding, without changing colored lattice vertices.
neutral = responses[:, :, diagonal, :]
correction = float(np.max(abs(neutral - neutral.mean(axis=-1, keepdims=True))))
responses[:, :, diagonal, :] = neutral.mean(axis=-1, keepdims=True)
blob = b'BRTN0001' + struct.pack('<I', 32) + responses.astype('<f4').tobytes()
args.output.write_bytes(blob)

def digest(path):
  return hashlib.sha256(path.read_bytes()).hexdigest()

args.manifest.write_text(json.dumps(dict(
  format='BRTN0001 + UInt32 dimension + Float32 responses[Whites/Blacks,knot,node,RGB]; little endian',
  dimension=32, responseKnots=model.knots.tolist(), parameters=model.keys,
  domain='encoded Display-P3; response deltas in linear Display-P3; R-fastest lattice',
  runtime='piecewise linear parameter response, tetrahedral RGB interpolation',
  neutralDiagonal='mean measured RGB delta', maximumNeutralCorrection=correction,
  limits='Pointwise SDR approximation; no image adaptation or measured Adobe HDR behavior',
  outputSHA256=digest(args.output), sourceSHA256=digest(Path(__file__)),
  pointModelSHA256=digest(Path(__file__).with_name('point_model.py')),
  references=model.evidence), indent=2) + '\n')
print(digest(args.output), len(blob), 'bytes', len(model.evidence), 'references')
