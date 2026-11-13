"""Print per-case p95 errors, optionally comparing a candidate to the same evidence and runtime."""
import argparse
import json
from pathlib import Path

from reference_pack import require


def rows(report):
  rows = {(r['id'],r['mode']): r for r in report['cases']}
  require(len(rows) == len(report['cases']) == report['work']['comparedImages']
    and rows and report['work']['failures'] == 0, 'Incomplete run')
  return rows


def score(candidate, baseline=None):
  current = rows(candidate)
  previous = rows(baseline) if baseline is not None else None
  if previous is not None:
    for key in ('runtime', 'comparatorSHA256', 'measurement', 'pairedNeutral'):
      require(candidate[key] == baseline[key], f'Different {key}; rerun both builds on the same worker')
    require(current.keys() == previous.keys(), 'Different cases or modes')
    for k, r in current.items():
      for key in ('inputSHA256','settingsSHA256','referenceSHA256','outputICCSHA256','neutralID','role','sourceRole'):
        require(r[key] == previous[k][key], f'Different {key} for {k}')
  def p95(row, paired):
    metrics = row['metrics']
    if paired:
      metrics = metrics.get('adjustmentResponseError')
    return metrics['pixelMaxChannelError']['p95'] if metrics else None
  print('case | mode | absolute p95 | response p95' + (' | Δ absolute | Δ response' if previous else ''))
  print('--- | --- | ---: | ---:' + (' | ---: | ---:' if previous else ''))
  for k,r in sorted(current.items()):
    values = [p95(r, False), p95(r, True)]
    columns = [*k, *(f'{v:.6f}' if v is not None else '—' for v in values)]
    if previous is not None:
      for paired, value in enumerate(values):
        before = p95(previous[k], bool(paired))
        require((before is None) == (value is None), f'Different response evidence for {k}')
        columns.append(f'{value-before:+.6f}' if value is not None else '—')
    print(' | '.join(columns))


if __name__ == '__main__':
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('candidate', type=Path)
  parser.add_argument('--baseline', type=Path, help='reference run of an earlier Brightroom revision; negative Δ is closer')
  args = parser.parse_args()
  score(json.loads(args.candidate.read_text()), json.loads(args.baseline.read_text()) if args.baseline else None)
