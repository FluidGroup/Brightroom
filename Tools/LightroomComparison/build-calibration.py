"""Compile measured gray curves, excluding every held-out case."""
from pathlib import Path
import argparse
import json
import hashlib
import numpy as np
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('research',type=Path)
parser.add_argument('output',type=Path)
args=parser.parse_args()
research=args.research.resolve()
assert not args.output.exists(), 'Do not overwrite calibration evidence'
retained=json.loads(Path(__file__).with_name('calibration.json').read_text())
retained_by_id={r['id']:r for r in retained['calibrationReferences']}
neutral=research/'grading-pixels/grading-neutral.rgba32f'
assert hashlib.sha256(neutral.read_bytes()).hexdigest()==retained['neutralDecodedSHA256']
# ROMM RGB D50 and Display-P3 D65, with Bradford white adaptation.
def rgbxyz(primaries,white):
  p=np.array([[x/y,1,(1-x-y)/y] for x,y in primaries]).T
  x,y=white
  return p @ np.diag(np.linalg.solve(p,[x/y,1,(1-x-y)/y]))
p3=rgbxyz([(0.68,0.32),(0.265,0.69),(0.15,0.06)],(0.3127,0.3290))
pp=rgbxyz([(0.7347,0.2653),(0.1596,0.8404),(0.0366,0.0001)],(0.3457,0.3585))
b=np.array([[.8951,.2664,-.1614],[-.7502,1.7135,.0367],[.0389,-.0685,1.0296]])
def white(x,y):return np.array([x/y,1,(1-x-y)/y])
adapt=np.linalg.inv(b) @ np.diag((b@white(.3457,.3585))/(b@white(.3127,.3290))) @ b
M=np.linalg.inv(pp) @ adapt @ p3

x=(np.fromfile(neutral,dtype='<f4').reshape(256,1024,4)[32,:,:3].astype(float)@M.T).mean(axis=1)
nodes=np.linspace(0,1,257)
linear=np.where(nodes<=.04045,nodes/12.92,((nodes+.055)/1.055)**2.4)
refs={}
for manifest in ['grading-references.json','grading-grid-references.json']:
 for item in json.loads((research/manifest).read_text())['references']:
  refs[item['id']]=item
used=set()
def read(name):
 item=refs[name];p=research/item['reference'];assert hashlib.sha256(p.read_bytes()).hexdigest()==item['referenceSHA256']
 frozen=retained_by_id[name]
 assert item['referenceSHA256']==frozen['sha256']
 assert hashlib.sha256((research/frozen['decoded']).read_bytes()).hexdigest()==frozen['decodedSHA256']
 used.add(name)
 folder='grading-grid-pixels' if name.startswith('grading-grid-') else 'grading-pixels'
 pp=np.fromfile(research/folder/(name+'.rgba32f'),dtype='<f4').reshape(256,1024,4)[32,:,:3]@M.T
 return np.column_stack([np.interp(linear,x,pp[:,c]) for c in range(3)])
# Binary layout: color[range, blend, balance, saturation, role, sample],
# midtones[blend, balance, role, sample], luminance[range, blend, balance, amount, sample].
color=np.empty((2,5,5,5,3,257))
mid=np.empty((5,5,2,257))
lum=np.empty((3,5,5,5,257))
for gi,g in enumerate(['shadows','midtones','highlights']):
 for bi,b in enumerate([0,25,50,75,100]):
  for ai,a in enumerate([-100,-50,0,50,100]):
   if g=='midtones':
    v=read(f'grading-{g}-color-b{b}-a{a:+d}')
    mid[bi,ai]=[v[:,0],v[:,1:].mean(axis=1)]
   else:
    ci=0 if g=='shadows' else 1
    color[ci,bi,ai,0]=[linear]*3
    for si,s in enumerate([25,50,75,100],1):
     pn=f'grading-{g}-color-b{b}-a{a:+d}' if s==100 else f'grading-grid-{g}-h0-s{s}-b{b}-a{a:+d}'
     p=read(pn);q=read(f'grading-grid-{g}-h60-s{s}-b{b}-a{a:+d}')
     color[ci,bi,ai,si]=[p[:,0],p[:,1:].mean(axis=1),q[:,2]]
   for li,l in enumerate([-100,-50,0,50,100]):
    if l==0:lum[gi,bi,ai,li]=linear;continue
    n=f"grading-{g}-lum-{'positive' if l>0 else 'negative'}-b{b}-a{a:+d}" if abs(l)==100 else f'grading-grid-{g}-l{l:+d}-b{b}-a{a:+d}'
    lum[gi,bi,ai,li]=read(n).mean(axis=1)

args.output.parent.mkdir(parents=True,exist_ok=True)
values=np.concatenate([color.ravel(),mid.ravel(),lum.ravel()]);assert np.isfinite(values).all()
data=b'BRCG0001'+np.round(np.clip(values,0,1)*65535).astype('<u2').tobytes()
assert hashlib.sha256(data).hexdigest()==retained['sha256'], 'Calibration reproduction changed'
args.output.write_bytes(data)
report={'model':'BRCG0001','sampleCount':257,'encoding':'UInt16 little-endian, linear ProPhoto RGB / 65535','sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'calibrationReferences':[{'id':n,'sha256':refs[n]['referenceSHA256'],'settingsSHA256':refs[n]['settingsSHA256']} for n in sorted(used)]}
args.output.with_suffix('.json').write_text(json.dumps(report,indent=2)+'\n')
print(len(used),'calibration cases',len(data),'bytes')
