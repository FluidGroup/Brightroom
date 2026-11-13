"""Confirm the fixed public charts were actually rendered, without rating color compatibility."""
import json
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text())
expected = {f'adaptive-near-{background}-{control}': direction
  for background in ('dark', 'light') for control, direction in
  [('neutral', 0), ('Highlights2012--50', -1), ('Shadows2012-50', 1), ('Whites2012-25', 1)]}
if len(report['cases']) != len(expected) or {r['id'] for r in report['cases']} != expected.keys():
  raise ValueError('Expected both neutrals and all six light edits')
for row in report['cases']:
  m, direction = row['metrics'], expected[row['id']]
  if row['mode'] != 'adaptive' or m['allPixels']['pixels'] != 1024 * 256:
    raise ValueError(f"Wrong render mode or chart dimensions: {row['id']}")
  if direction == 0:
    # The chart has true black and white patches. A flat/blank render is not a baseline.
    low, high = m['candidateChannelRange']
    if low > 0.01 or high < 0.99:
      raise ValueError(f"Missing grayscale range: {row['id']}")
  else:
    bands = m['adjustmentResponseError']['byNeutralLuminance'].values()
    for field in ('referenceMeanChange', 'candidateMeanChange'):
      if direction * sum(b['pixels'] * b.get(field, 0) for b in bands) <= 0:
        raise ValueError(f"No visible change in the expected direction: {row['id']} {field}")
print('Verified eight chart renders and the direction of all six adjustments.')
