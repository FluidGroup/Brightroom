"""Read registered, ICC-decoded reference data with hash and shape checks."""
import hashlib
import json
from pathlib import Path
import numpy as np


# The color transform used by ColorAdjustmentWorkingSpace.metalh.
P3_TO_ROMM = np.array([
    [.63169122, .21392818, .15438059],
    [.08320432, .88585751, .03093817],
    [-.00127273, .05075510, .95051763],
])

class FrozenSet:
    """One immutable acquisition. Only actually consumed references are recorded."""

    def __init__(self, root):
        self.root = Path(root)
        self.references = {r['id']: r for r in json.loads((self.root / 'references.json').read_text())['references']}
        self.decoded = {Path(r['input']).stem: r for r in json.loads((self.root / 'decoded/manifest.json').read_text())}
        self.evidence = {}

    def read(self, identity):
        reference = self.references[identity]
        decoded = self.decoded[identity]
        path = self.root / reference['reference']
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        if not digest == reference['referenceSHA256'] == decoded['sha256']:
            raise ValueError(f'Changed or stale reference: {identity}')
        data = (self.root / 'decoded' / (identity + '.rgba32f')).read_bytes()
        pixels = np.frombuffer(data, '<f4').reshape(decoded['height'], decoded['width'], 4)
        if not np.isfinite(pixels).all() or np.max(abs(pixels[..., 3] - 1)) >= 1e-6:
            raise ValueError(f'Nonfinite or nonopaque decoded reference: {identity}')
        self.evidence[identity] = dict(set=self.root.name, id=identity,
            referenceSHA256=digest, decodedSHA256=hashlib.sha256(data).hexdigest())
        return pixels
