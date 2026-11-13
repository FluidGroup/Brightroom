"""Select sharing between neighboring luminance bins using complete registered Highlights −50 renders."""
import argparse
from collections import Counter
import json
from pathlib import Path

import numpy as np

from tone_chart import digest


def read(path):
    return json.loads(path.read_text())


def fit(baseline, candidates, calibration):
    """Compare the same sources, references and pixel counts in every public GPU run."""
    manifest = read(calibration)
    if manifest['control'] != 'Highlights2012' or manifest['amount'] != -50:
        raise ValueError('Expected a signed Highlights −50 calibration manifest')
    sources = {row['id']: row for row in manifest['sources']}
    if len(sources) != len(manifest['sources']) or len({row['source'] for row in sources.values()}) != len(sources):
        raise ValueError('Duplicate calibration case or source')
    families = np.array([row['family'] for row in sources.values()])
    if Counter(families) != {'photo': 9, 'chart': 24, 'cube': 1}:
        raise ValueError('Expected nine photographs, 24 spatial charts and the color lattice')

    def rows(report):
        selected = {row['id']: row for row in report['rows'] if row['id'] in sources}
        if len(selected) != len(sources) or sum(row['id'] in sources for row in report['rows']) != len(sources):
            raise ValueError('Missing or repeated calibration case in native report')
        for key, source in sources.items():
            row = selected[key]
            if (row['ctl'] != 'Highlights2012' or row['v'] != -50 or not row['fit']
                    or row['family'] != source['family'] or row['pixels'] <= 0
                    or any(row[a] != source[b] for a, b in (
                        ('source', 'source'), ('icc', 'icc'), ('xmp', 'xmp'), ('t', 'reference'), ('n', 'neutral')))):
                raise ValueError(f'Unregistered source, XMP or paired output for {key}')
        return selected

    old = read(baseline)
    before = rows(old)
    if old['kernel'] != manifest['baselineKernel']:
        raise ValueError('Baseline kernel differs from the registered capture')
    names = ['original']
    changes = [np.zeros(len(sources))]
    for path in candidates:
        report = read(path)
        if report['beforeKernel'] != old['kernel']:
            raise ValueError(f'Unrelated baseline in {path}')
        new = rows(report)
        for key in sources:
            if (new[key]['priorRGB'] != before[key]['rgb'] or new[key]['before'] != before[key]['after']
                    or new[key]['pixels'] != before[key]['pixels']):
                raise ValueError(f'Native baseline changed for {key}')
        names.append(path.name)
        changes.append([new[k]['after'] - before[k]['after'] for k in sources])

    values = np.array(changes).T
    if len(set(names)) != len(names) or not np.isfinite(values).all():
        raise ValueError('Expected unique candidates with finite scores')

    def score(matrix, included):
        weights = np.zeros(len(families))
        for family, share in [('photo', .55), ('chart', .30), ('cube', .15)]:
            selected = included & (families == family)
            if selected.any():
                weights[selected] = share / selected.sum()
        return weights @ (matrix + np.maximum(matrix, 0)) + .07 * matrix[included].max(axis=0)

    indexes = np.arange(len(sources))
    full = np.ones(len(sources), dtype=bool)
    scores = score(values, full)
    folds = [score(values, indexes != i).argmin() for i in indexes]
    return dict(selected=names[scores.argmin()], scores=dict(zip(names, scores)),
                leaveOneSourceOut=dict(zip(sources, (names[i] for i in folds))),
                heldSourceScore=score(values[indexes, folds], full),
                files={path.name: digest(path) for path in [baseline, *candidates, calibration]})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('calibration', type=Path)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidates', nargs='+', type=Path)
    args = parser.parse_args()
    print(json.dumps(fit(args.baseline, args.candidates, args.calibration), indent=2, allow_nan=False))
