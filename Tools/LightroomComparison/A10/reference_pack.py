"""Move registered Lightroom evidence between machines without rewriting image or XMP bytes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import zipfile

ASSET = re.compile(r'assets/([0-9a-f]{64})\.(tif|xmp|icc)')
MANIFESTS = ('cases.json', 'references.json')


def require(condition, message):
  if not condition:
    raise ValueError(message)


def file_hash(path):
  with path.open('rb') as stream:
    return hashlib.file_digest(stream, 'sha256').hexdigest()


def case_id(value):
  require(isinstance(value, str) and re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', value),
    f'Invalid case ID: {value!r}')
  return value


def profile_of(reference):
  """Return the frozen output profile, or let the renderer read the original TIFF's ICC."""
  inspection = reference.get('inspection', {})
  if 'icc' in inspection:
    require(inspection['sha256'] == reference['referenceSHA256'],
      f"ICC inspection belongs to a different image: {reference['id']}")
    inspected = {'path': inspection['icc'], 'sha256': inspection['iccSHA256']}
    if 'outputICC' in reference:
      require(reference['outputICC']['sha256'] == inspected['sha256'],
        f"Conflicting output profiles: {reference['id']}")
    else:
      return inspected
  return reference.get('outputICC')


def registration(source, temporary):
  """Open a trusted capture directory or materialize a self-contained pack for one run."""
  if source.is_dir():
    return source
  with zipfile.ZipFile(source) as archive:
    destination = Path(temporary.enter_context(tempfile.TemporaryDirectory(prefix='brightroom-replay-')))
    names = archive.namelist()
    require(len(names) == len(set(names)) and set(MANIFESTS) <= set(names),
      'Duplicate archive member or missing manifest')
    for name in names:
      asset = ASSET.fullmatch(name)
      require(asset or name in MANIFESTS, f'Unexpected archive member: {name}')
      path = destination/name
      path.parent.mkdir(exist_ok=True)
      with archive.open(name) as src, path.open('xb') as dst:
        shutil.copyfileobj(src, dst)
      if asset:
        require(file_hash(path) == asset[1], f'Asset does not match its name: {name}')
    # Registration directories on the capture Mac may name external originals. A
    # distributed pack must resolve every path it can render inside the archive.
    def member(path, digest, suffix):
      require(path == f'assets/{digest}.{suffix}' and path in names and ASSET.fullmatch(path),
        f'Invalid packed asset: {path!r}')
    for manifest in MANIFESTS:
      document = json.loads((destination/manifest).read_text())
      require(document.get('packVersion') == 1, f'Unknown pack version: {manifest}')
      for row in document[manifest[:-5]]:
        case_id(row['id'])
        if manifest == 'cases.json':
          member(row['input'], row['inputSHA256'], 'tif')
          member(row['settings'], row['settingsSHA256'], 'xmp')
        else:
          member(row['reference'], row['referenceSHA256'], 'tif')
          profile = profile_of(row)
          if profile is not None:
            member(profile['path'], profile['sha256'], 'icc')
          inspection = row.get('inspection', {})
          if 'metadata' in inspection:
            member(inspection['metadata'], inspection['metadataSHA256'], 'xmp')
  return destination


def pack(source, destination, selected):
  """Build a new ZIP from an existing registration; choose neutrals by the source hash."""
  cases, refs = [json.loads((source/name).read_text()) for name in MANIFESTS]
  def indexed(rows):
    records = {case_id(r['id']): r for r in rows}
    require(len(records) == len(rows), 'Duplicate case or reference ID')
    return records
  by_id = indexed(cases['cases'])
  references = indexed(refs['references'])
  ids = set(selected or by_id)
  require(ids and ids <= by_id.keys(), f'No cases or unknown IDs: {sorted(ids-by_id.keys())}')
  for identity in sorted(ids):
    matches = [c['id'] for c in by_id.values() if c['group'] == 'neutral'
      and c['inputSHA256'] == by_id[identity]['inputSHA256']]
    require(len(matches) <= 1, f'Ambiguous same-input neutral for {identity}')
    ids.update(matches)
  require(ids <= references.keys(), f'Missing references: {sorted(ids-references.keys())}')
  assets, checked = {}, set()
  def asset(path, expected, suffix):
    path = source/path
    name = f'assets/{expected}.{suffix}'
    require(ASSET.fullmatch(name), f'Invalid asset hash: {expected!r}')
    if (path, expected) not in checked:
      require(file_hash(path) == expected, f'Frozen evidence changed: {path}')
      checked.add((path, expected))
    assets.setdefault(name, path)
    return name
  packed_cases, packed_refs = [], []
  for identity in sorted(ids):
    c, r = by_id[identity], references[identity]
    require(c['settingsSHA256'] == r['settingsSHA256'], f'Reference settings mismatch: {identity}')
    require((source/c['input']).suffix.lower() in ('.tif', '.tiff'),
      'Only developed TIFF inputs are supported by this pack version')
    case = {k: c[k] for k in ('id','kind','group','role','parameters','sourceID','split','family',
      'inputSHA256','settingsSHA256') if k in c}
    case.update(input=asset(c['input'], c['inputSHA256'], 'tif'),
      settings=asset(c['settings'], c['settingsSHA256'], 'xmp'))
    reference = {k: r[k] for k in ('id','kind','group','referenceSHA256','settingsSHA256',
      'resolvedSettings','omittedInactiveSettings') if k in r}
    reference['reference'] = asset(r['reference'], r['referenceSHA256'], 'tif')
    profile = profile_of(r)
    if profile is not None:
      reference['outputICC'] = dict(path=asset(profile['path'], profile['sha256'], 'icc'), sha256=profile['sha256'])
    if 'inspection' in r:
      inspection = r['inspection']
      require(inspection['sha256'] == r['referenceSHA256'], f'Inspection does not match {identity}')
      retained = {k: inspection[k] for k in ('width','height','bits','alphaInfo','profile','sha256') if k in inspection}
      if 'metadata' in inspection:
        retained.update(metadata=asset(inspection['metadata'], inspection['metadataSHA256'], 'xmp'),
          metadataSHA256=inspection['metadataSHA256'])
      reference['inspection'] = retained
    packed_cases.append(case)
    packed_refs.append(reference)
  documents = [dict(cases=packed_cases),dict(export=refs['export'],references=packed_refs)]
  require(not destination.exists(), f'Output already exists: {destination}')
  destination.parent.mkdir(parents=True, exist_ok=True)
  # Fixed dates, ordering and file attributes keep repacking the same registration reproducible.
  def entry(name):
    info = zipfile.ZipInfo(name)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info
  with tempfile.TemporaryDirectory(dir=destination.parent) as scratch:
    completed = Path(scratch)/'complete.zip'
    with zipfile.ZipFile(completed, 'w') as archive:
      for name, document in zip(MANIFESTS, documents):
        document.update(packVersion=1, registrationSHA256=file_hash(source/name))
        archive.writestr(entry(name), json.dumps(document, indent=2, sort_keys=True)+'\n')
      for name, path in sorted(assets.items()):
        with path.open('rb') as src, archive.open(entry(name), 'w') as dst:
          # Bind the bytes actually written even if the source changed after validation.
          h = hashlib.sha256()
          while chunk := src.read(1024*1024):
            dst.write(chunk)
            h.update(chunk)
          require(h.hexdigest() == ASSET.fullmatch(name)[1], f'Frozen evidence changed: {path}')
    os.link(completed, destination)
  print(f'{destination}: {len(ids)} cases, {len(assets)} assets, sha256 {file_hash(destination)}')


if __name__ == '__main__':
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('registration', type=Path, help='verified directory produced by the capture tools')
  parser.add_argument('new_zip', type=Path)
  parser.add_argument('--case-id', action='append', help='repeat to select cases; include their neutrals if captured')
  args = parser.parse_args()
  pack(args.registration, args.new_zip, args.case_id)
