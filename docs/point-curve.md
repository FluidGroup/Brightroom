# Point curves

`PointCurveFeature` applies a master curve and three independent RGB curves
to developed pixels. It accepts the Camera Raw Refine Saturation amount
directly. Measurements use Lightroom Classic PV 15.4. [A10 comparison](../Tools/LightroomComparison/A10/README.md)

```swift
let master = ToneCurve(validating: [
  .init(input: 0, output: 0),
  .init(input: 128.0 / 255, output: 160.0 / 255),
  .init(input: 1, output: 1),
])!
let effect = PointCurveFeature(curves: .init(master: master), refineSaturation: 50)
```

## Interpretation

Version 2 uses ROMM/ProPhoto RGB primaries with the sRGB transfer function.
ProPhoto RGB files use their own transfer function. Host-side XMP points are
divided by 255 on both axes. Input pixels are color matched into extended-linear
Display-P3, then converted into linear ROMM with Bradford white adaptation.

The master samples a line through two points on the spline for each pixel.
Let `t` be the middle encoded component's position between the minimum and
maximum. Set `k = 0.5 * t * (1 - t)`. On that interval the two samples are at
`k * (1 - t)` and `1 - k * t`. Extend their line to the two ends, bound each
result to 0...1, and reconstruct all three components at their original
relative positions. A gray pixel samples the curve directly.

`refineSaturation` ranges from 0 through 100. At 100 the feature uses this
master response. At zero it retains the input's encoded RGB differences around
the luma of the three independently mapped components, with weights 0.30,
0.59 and 0.11. It reduces their common spread just enough to fit in the SDR
gamut. Intermediate values blend these results in encoded ROMM. The red,
green and blue curves then act on their respective channels. This order was
checked with A10 at 100. Only the master midtone-lift chart has separate
Lightroom exports at 0 and 50. Adobe describes the slider and its default
in the [Camera Raw Curve panel guide](https://helpx.adobe.com/camera-raw/desktop/using/make-color-tonal-adjustments-camera.html).

Each curve is a natural cubic spline with zero second derivative at its
endpoints. Inward endpoints create constant exterior intervals. Spline output
can overshoot between points and is bounded to 0...1. The shader samples 4,096 entries per
curve, packed as deltas into one 8,192-pixel RGf strip. Compiled tables are
created once per feature value and do not participate in equality.

The measured domain is SDR. Outside linear ROMM 0...1, the bounded transform
is extended by the input's original excess, giving unit-slope continuation.
Adobe HDR response remains unmeasured. Alpha and input extent are preserved.
A floating-point working format retains out-of-gamut and extended-range values.

## Authoring and persistence

`Curves` holds the `master`, `red`, `green`, and `blue` point curves.
All default to identity. To change a curve, edit a copy and construct a new
feature. Refinement can be changed in place without
recompiling its table. Equality compares the authored coordinates and refinement.
`init(curves:)` uses refinement 100. `init(validatingCurves:refineSaturation:)`
rejects nonfinite or out-of-range refinement when restoring stored edits.
Redundant diagonal points remain authored data, while an entirely diagonal
mapping returns the input CIImage itself without a kernel or color conversion.

`ToneCurve` accepts 2...12 points, finite coordinates in 0...1, and at least
0.02 spacing on the input axis. The research XMP adapter rejects points
outside those limits. Hosts can store the authored coordinates and refinement
in their own format and reconstruct the feature through the public validating
initializer.

`ToneCurveFeature` provides the existing stop-domain shaper, PCHIP
interpolation, and YRGB semantics. Hosts can compose `PointCurveFeature`
in their own edit.

## Measured response

Both engines received the same 16-bit TIFF and XMP. Each version of
Brightroom exported with the profile embedded in the Lightroom reference.
Errors below are the 95th percentile of
each pixel's largest absolute channel difference in linear Display-P3,
with white at 1. Neutral p95 was 0.000171 on the Display-P3 chart and
0.000078 on the photograph.

| Input and XMP setting | Version 1 | Version 2 |
|---|---:|---:|
| Display-P3 chart, A10 RGB curves only | 0.000501 | 0.000501 |
| Display-P3 chart, A10 master only | 0.018475 | 0.000369 |
| Display-P3 chart, A10 master and RGB | 0.017076 | 0.000429 |
| Display-P3 chart, midtone lift | 0.018843 | 0.000429 |
| Display-P3 chart, midtone reduction | 0.014821 | 0.000659 |
| Display-P3 chart, quarter-tone lift | 0.022607 | 0.000433 |
| 24 MP photograph, A10 master and RGB | 0.000935 | 0.000295 |
| ProPhoto midtone lift, refinement 0 | 0.117594 | 0.000560 |
| ProPhoto midtone lift, refinement 50 | 0.064370 | 0.000486 |
| ProPhoto midtone lift, refinement 100 | 0.036956 | 0.000469 |

Version 1 used its default master response for all refinement amounts. A few
saturated ProPhoto colors still have larger differences. At refinement 0 the
maximum was 0.132139 and the neutral maximum was 0.054880. Feeding Lightroom's
neutral export into the same version 2 feature reduced that refinement-0
maximum to 0.003169. On the original photograph the A10 point-curve maximum
dropped from 0.030588 to 0.000766.

The master sampling model was identified on the Display-P3 midtone lift.
Other curve shapes and the photograph were evaluated separately. For the
A10 curve group on the photograph, supplying Lightroom's region-only
output before the public point curve reduced p95 from 0.03140 to 0.00029.
This diagnostic uses an Adobe intermediate. Region sliders such as
`ParametricDarks` remain outside this feature. On the supplied common TIFF,
the complete partial A10 stack had p95 0.045925 before the point-curve
change and 0.046144 afterwards.

The [comparison loop](../Tools/LightroomComparison/A10/README.md) replays
the original inputs and records absolute and paired-neutral RGB error.
iOS renderer tests cover independent Adobe color samples at 0, 50 and 100,
the gamut boundary, analytic grayscale, identity, authored equality,
working-space consistency, alpha, extent and extended-range values.
