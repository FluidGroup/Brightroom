"""Fit positive-Whites strength from synthetic scene statistics only.

Leave-one-scene-out error selects the blur radius and ridge penalty. This
calibration is independent of photographic, color-scene, and A10 validation.
"""
from pathlib import Path
import argparse, json
import numpy as np
from adaptive_data import FrozenSet
from scipy.ndimage import gaussian_filter
from point_model import PointModel
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('research',type=Path)
parser.add_argument('output',type=Path)
args=parser.parse_args()
assert not args.output.exists(), 'Do not overwrite evidence'
m=PointModel(args.research/'adjustments-001',args.research/'response-model-001',keys=['Whites2012'])
curves=m.responses['Whites2012'][:,np.arange(32)*1057].mean(axis=-1)
roots=[FrozenSet(args.research/'adaptive-002'),FrozenSet(args.research/'adaptive-calibration-001')]
names=['ramp','permuted','near-dark','near-light','dark','light','flat-10','flat-25','flat-50','flat-75','flat-90','low-ramp','mid-ramp','high-ramp']
def enc(x):return np.where(x<=.0031308,12.92*x,1.055*np.maximum(x,0)**(1/2.4)-.055)
def read(n,key):
 i=0 if n in names[:6] else 1;prefix='adaptive-' if i==0 else 'adaptcal-'
 return roots[i].read(f'{prefix}{n}-{key}')[:,:,:3].mean(2).astype(float)
records=[];xs=[]
for n in names:
 x=read(n,'neutral');b=read(n,'Whites2012-25')
 # Keep the same ramp stripe for nonuniform scenes, and all samples of flat fields.
 xx=x[128,::2];yy=b[128,::2];ex=enc(xx)
 if n=='permuted':xx=x[128];yy=b[128];ex=enc(xx)
 errors=[]
 for strength in np.arange(1,1001)/10:
  i=np.clip(np.searchsorted(m.knots,strength,side='right')-1,0,7)
  f=(strength-m.knots[i])/(m.knots[i+1]-m.knots[i]);c=curves[i]*(1-f)+curves[i+1]*f
  pred=np.clip(xx+np.interp(ex,np.arange(32)/31,c),0,1)
  errors.append(np.mean((pred-yy)**2))
 strength=(np.argmin(errors)+1)/10
 records.append(dict(name=n,strength=strength,rms=float(np.sqrt(min(errors)))))
 xs.append(x)
print(records,flush=True)
# Fit only synthetic scene statistics. Leave-one-scene-out scores select the
# smoothing radius and regularization; the photograph never enters this fit.
ys=np.log(np.array([r['strength']/25 for r in records]))
options=[]
for sigma in [1,2,4,8,16,32,64]:
 stats=[]
 for x in xs:
  v=enc(gaussian_filter(x,sigma,mode='nearest'))
  mu=v.mean();var=v.var();skew=np.mean((v-mu)**3)
  stats.append([1,mu,mu*mu,var,skew])
 a=np.array(stats)
 for ridge in [.00001,.0001,.001,.01]:
  pred=[]
  for j in range(len(names)):
   keep=np.arange(len(names))!=j
   c=np.linalg.solve(a[keep].T@a[keep]+np.eye(5)*ridge,a[keep].T@ys[keep])
   pred.append(a[j]@c)
  error=np.mean((pred-ys)**2)
  coef=np.linalg.solve(a.T@a+np.eye(5)*ridge,a.T@ys)
  options.append(dict(sigma=sigma,ridge=ridge,looRMS=float(np.sqrt(error)),coef=coef.tolist(),predicted=(25*np.exp(a@coef)).tolist(),loo=(25*np.exp(pred)).tolist()))
best=min(options,key=lambda x:x['looRMS'])
print('best',best,flush=True)
args.output.write_text(json.dumps(dict(records=records,best=best,options=options,
 references=m.evidence+[r for root in roots for r in root.evidence.values()]),indent=2)+'\n')
