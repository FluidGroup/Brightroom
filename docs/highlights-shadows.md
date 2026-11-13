# Spatial Highlights and Shadows

`HighlightsShadowsFeature` takes the two signed Camera Raw sliders together
on an already developed RGB image. It can be used directly in a feature body.

```swift
let effects = [
  AnyImageEffect(HighlightsShadowsFeature(highlights: -37, shadows: 17)),
  AnyImageEffect(WhitesFeature(amount: 42)),
]
```

Pass `Highlights2012` and `Shadows2012` directly, each in −100...100. For
negative Highlights and positive Shadows, the joint feature reduces each
slider's effective strength as the other grows. It applies Shadows, then
measures Highlights on the result. One −35/+42 chart provided the interaction
measurement. The −11/+30 combination and one photograph at both settings
were compared separately. Predictions near the ends of the sliders still
need paired photographic references. Other sign combinations use each full
individual strength in the same order. A zero amount leaves the other
slider's individual response intact.

For independently authored stages, `HighlightsFeature(lightroomAmount:)` and
`ShadowsFeature(lightroomAmount:)` select the spatial algorithm individually.
Their conversions into the existing `value` API are `-amount / 100` for
Highlights and `amount / 100` for Shadows. The default algorithm in those
types is `.coreImage`.
The approximation evaluates finite values clamped to -1...1 and bypasses
nonfinite values. It retains the authored `value`; hosts should validate their
storage models. Zero returns the input image itself. Algorithm selection is part
of value equality and must be retained when an app persists an edit.

## Measured behavior and implementation

Lightroom left five uniform gray fields unchanged at H/S +/-50. Rearranging
pixels while preserving their histogram changed its response. Swapping near and
distant surrounds while keeping the same histogram also changed H/S. These
observations establish spatial dependence; they do not identify Adobe's kernel.

The approximation uses nine measurements of logarithmic linear-P3 luminance:
the pixel value, four relative Gaussian neighborhoods, two local deviations,
and the image-wide mean and deviation. A small immutable radial-basis model
predicts encoded-P3 changes. Both RGB extrema are adjusted and the middle
channel is interpolated between them to preserve RGB hue. The amount axis uses
separate measurements at 0/10/25/50/100 in each direction.

The base spatial model uses synthetic grayscale scenes. Five synthetic scenes
select its representation and regularization. Its builder is
`Light/fit-spatial.py`, with registered hashes in `Light/spatial-calibration.json`.

Negative Highlights also uses the image-wide mean log luminance and the
standard deviation of its least-blurred guide. A 65×33 table gives a positive
gain for the **linear RGB change from −25 to −50**. This defines the −50
endpoint. Stronger settings continue with the base increments beyond −50.
The gain was calibrated on −50 exports of 24 synthetic scenes and nine
photographs. Each scene was left out in turn to select the fit parameters.
The supplied A10 output and nine separate evaluation photographs were excluded
from the fit. The builder and calibration samples are in
`Light/build-highlights-strength.py` and `Light/highlights-strength-calibration.json`.

Negative Shadows evaluates the base response at the pixel's linear-P3
luminance. It applies the resulting encoded change to both RGB extrema, then
interpolates the middle channel. The grayscale response is retained.

Negative Highlights and Shadows also adjust the RGB distance from gray at
their −50 anchor. Highlights uses the encoded RGB span. Shadows uses the
encoded red and blue offsets from luminance. Five luminance knots per control
describe the measured response. Thirteen calibration scenes contributed
paired neutral and −50 exports, including four colored charts and nine photos.
Negative Shadows follows the spatial model's luminance between zero and −50.
Weak negative Highlights uses a tone-dependent curve. Neutral, −10, −25 and −50 exports of a gray
ramp and an RGB chart determine how far each linear ProPhoto RGB extremum
moves. The peak P3 channel follows its measured fraction. The low channel
blends it with the spatial color response according to the input minimum
divided by the maximum. Gray and near-white pixels therefore follow the curve,
and saturated secondary channels retain more of their measured spatial response.
Beyond −50, Shadows extends its own measured strength curve toward black.
Highlights combines the spatial model's −100 endpoint with the measured
change of the two ProPhoto RGB extrema from −50 toward that endpoint.
[Strength calibration](../Tools/LightroomComparison/Light/README.md#negative-slider-strength)

At the same −50 anchor, negative Highlights also uses the log-luminance
differences between the pixel, the four spatial guides and the scene mean.
Negative Shadows uses the pixel's log-luminance difference from that mean.
Five luminance knots scale the encoded change to both color extrema. The
endpoint is bounded by its weaker setting so that slider motion stays monotonic.
The fit uses 24 synthetic scenes and nine photographs. [Calibration procedure](../Tools/LightroomComparison/Light/README.md#negative-highlights-and-shadows)

For colored pixels between −25 and −50, Highlights uses the source luminance,
the loss predicted at −50, and the mean and deviation of the scene's log
luminance. Four color layouts and nine photographs determine a 33×33 response
surface evaluated on the GPU for that image. The −25 color and corrected −50
color are fixed endpoints. The slider moves all channels between them with
one strength coordinate. Smaller settings retain their separately measured
response. Beyond −50, three coefficients fitted to 32,768 colors scale the
additional RGB losses. The adjustment vanishes on grays.

On the same 13 photographs, mean per-image RGB p95 in linear Display P3 fell
from 0.038491 to 0.031620 at −37 and from 0.050278 to 0.041845 at −50.
On the four photographs excluded from the −50 fit, the latter fell from
0.054005 to 0.043003. The −100 lattice p95 fell from 0.132345 to 0.082813.
The supplied A10 preset uses −11. Its full-frame comparison remains 0.046474.
[Color response calibration](../Tools/LightroomComparison/Light/README.md#highlight-color-response)

Some saturated Display P3 inputs acquire a negative linear P3 channel when
Lightroom lowers Highlights or Shadows and exports to ProPhoto RGB. The
shader uses the source color in linear ProPhoto RGB to measure how far its
darkest P3 channel can fall while keeping the same hue. The correction
reaches full strength at a zero P3 minimum and fades out over 40% of the
difference between the two spaces' minimum channels. On the −50 RGB lattice
that margin includes at least 95% of colors with a Lightroom minimum below
−0.005.

Highlights uses the drop in P3 luminance to estimate the dark channel's
additional descent. Shadows uses the drop in the brightest P3 channel.
The gamut extension retains the brightest channel's calibrated response. The floor comes
from the brightest channel at −100 and the position of ProPhoto black on
the source hue line. A fixed floor lets the minimum continue to darken
smoothly as the slider moves. The spatial guides still measure P3 luminance.
[Measurements and reproduction](../Tools/LightroomComparison/Light/README.md#negative-highlights-and-shadows-near-display-p3-black)

The negative controls also measure how much of the surrounding image falls in
a luminance range. Highlights averages the distance below 0.5 in encoded
Display-P3 luminance. Shadows averages a weight that falls from one at 2/3
to zero at white. Both use the existing guides at relative radii 16, 64 and
256 and the whole-image average. These readings scale the two RGB extrema
together at −50, up to the first channel reaching its brighter anchor.
[Range measurements and reproduction](../Tools/LightroomComparison/Light/README.md#luminance-ranges-at-the-negative-endpoint)

The Core Image graph measures context on an image capped at 512 pixels on the
longest edge, without CPU readback, then applies the response to original RGB
pixels. Relative neighborhoods follow the feature's input extent, including an
upstream crop. A partial render still uses the whole feature input for its
statistics. Each output tile samples the four guides in analysis coordinates.
Its guide requests stay within that 512-pixel image even for a 6000×4000
export. This avoids allocating a camera-resolution guide for each tile. Alpha
is retained and excluded pixels carry no weight in reductions.
The SDR boundary response extends to out-of-range input values; it does not
reconstruct clipped RAW highlights or implement Adobe HDR processing.

## Public-API comparisons

Error is the 95th percentile of each pixel's largest absolute RGB difference in
linear Display-P3, white = 1. It is not Delta E or a visual match percentage.
All pixels were compared after matching export ICC profiles.

| Original spatial model, before the changes below | Core Image | Spatial approximation |
|---|---:|---:|
| Photograph, Highlights -37 | 0.027204 | 0.021155 |
| Photograph, Highlights +23 | 0.037732 | 0.008316 |
| Photograph, Shadows +17 | 0.016617 | 0.003816 |
| Photograph, Shadows -32 | 0.011738 | 0.005431 |
| New color scene, Highlights -37 | 0.017087 | **0.018297 (worse)** |
| New color scene, Highlights +23 | 0.033306 | 0.006587 |
| New color scene, Shadows +17 | 0.019585 | 0.011101 |
| New color scene, Shadows -32 | 0.015856 | **0.021360 (worse)** |

The first photograph is the existing scene rendered at 1500×1000. The colored
scene and these strengths were acquired prospectively for that comparison.

The following measurements compare the first public spatial features before and
after calibrating negative Highlights and changing how negative Shadows
handles color. Each row averages the per-image p95 over the given conditions.
The held-out Highlights row is a subset of the first two rows. Four of its
nine photographs have references at both strengths.

| Control and inputs | Conditions | Before | After | Improved |
|---|---:|---:|---:|---:|
| Highlights −37, photographs | 18 | 0.060568 | 0.046430 | 16 |
| Highlights −50, photographs | 13 | 0.087018 | 0.059323 | 12 |
| Highlights −37/−50, held-out photographs | 13 | 0.061084 | 0.048955 | 10 |
| Shadows −32/−50, photographs | 18 | 0.018594 | 0.018321 | 13 |
| Shadows −32/−50, colored charts | 7 | 0.017545 | 0.010778 | 7 |

The colored holdout's Highlights −37 p95 rose from 0.01830 to 0.01951.
The bright color photograph's Shadows −32 p95 rose from 0.01036 to 0.01319.

The subsequent −50 color calibration produced these half-float export results.
The evaluation photographs have been measured in earlier iterations and were
excluded from the fit. The held-out Highlights row covers nine photos at 13
settings. The held-out Shadows row covers the same nine photos at one setting each.

| Control and input | Conditions | Before color calibration | After color calibration | Improved |
|---|---:|---:|---:|---:|
| Highlights, photographs | 31 | 0.051837 | 0.051244 | 27 |
| Highlights, held-out photographs | 13 | 0.048955 | 0.048410 | 13 |
| Highlights, colored charts | 7 | 0.013658 | 0.013038 | 6 |
| Shadows, photographs | 18 | 0.018321 | 0.017627 | 14 |
| Shadows, held-out photographs | 9 | 0.014109 | 0.012944 | 9 |
| Shadows, colored charts | 7 | 0.010778 | 0.009207 | 7 |

The p95 on 33 grayscale charts per control stayed the same in both half- and
single-float rendering. Highlights −50 on photograph 004 regressed from
0.110836 to 0.112626. All 31 photographic Highlights conditions still exceed
0.01. Against their paired neutral exports, matching luminance perfectly in a
diagnostic on the previous model left a mean photographic p95 of 0.01257.
Luminance recovery remains the largest source of error in these photographs.

On the supplied 6000×4000 Apple RAW TIFF / Lightroom A10 pair, the older Core
Image H/S path had p95 **0.081229**. Applying the original `A10.xmp` with the
first spatial H/S features yielded p95 **0.042788**, median **0.008015**, and p99
**0.059037**. Both runs use the public Whites/Blacks features and the measured
Mixer. That stack still omits
Grain, Texture/Clarity/Dehaze, parametric-curve regions, noise reduction, and Adobe
profiles. A10 uses Highlights −11, Shadows +30 and Whites −22. Its p95 against
Lightroom stayed at 0.042788 through the −50 color calibration. A direct
comparison to the previous Brightroom render gave p95 zero, p99 0.00000262, and a maximum
difference of 0.002682 in linear P3.

Measured macOS render/decode/PNG-write time for one H/S control was 0.28-0.37 s
at 1500x1000, versus 0.24-0.25 s for Core Image. The complete A10 stack took
16.0 s at 24 MP. These are single local runs, not a device-performance guarantee.

With the neighborhood correction, all 129 negative-control cases were
rendered again in half- and single-precision contexts using the same output ICC
profiles. The table gives the mean image-level p95 of half-float exports.

| Setting | Inputs | Previous p95 | Neighborhood correction |
|---|---:|---:|---:|
| Highlights −37/−50, all photos | 31 settings | 0.051244 | 0.047525 |
| Highlights −37/−50, photos excluded from fitting | 13 settings on 9 photos | 0.048410 | 0.044966 |
| Shadows −32/−50, photos excluded from fitting | 9 photos | 0.012944 | 0.012901 |
| Highlights, colored charts | 7 settings | 0.013038 | 0.012182 |
| Shadows, colored charts | 7 settings | 0.009207 | 0.009172 |

Eleven of the thirteen held photographic Highlights settings improved. A
calibration photo at −50 went from 0.11263 to 0.12004. Eight of nine held
Shadows photos improved. The spatial guides already used by the public
feature supply the neighborhood measurements.

The next comparison paired Lightroom's zero, −37 and −50 settings on each of
13 photographs. Scaling the observed −50 change by 37/50 predicted its −37
change with a mean image-level p95 of 0.002674. The earlier neutral-weighted
linear interpolation gave the following public-feature results.

| Highlights | Inputs | Previous p95 | With interpolation |
|---|---|---:|---:|
| −37 | 13 paired photographs | 0.047821 | 0.041818 |
| −37 | 5 other photographs | 0.032561 | 0.029878 |
| −50 | 13 paired photographs | 0.052985 | 0.052985 |
| −11 | A10 photograph, Highlights only | 0.006533 | 0.005211 |
| −10 | gray ramp | 0.018536 | 0.010577 |
| −25 | gray ramp | 0.041966 | 0.026399 |

Eleven of the 13 photographs and all five other photographs improved at −37.
The two regressions were 0.022191 → 0.027163 and 0.020196 → 0.020252.
Nine of the 13 photographs also contributed to the earlier −50 calibration.
Interpolating every color fully in linear RGB produced a larger error in the
blue channel of the saturated green test patch. Retaining the color response
in proportion to RGB saturation kept the existing chart tolerance.

With the measured strength curve, those 13 photographs improved from
0.041818 to 0.040472 at −37 (11 improved). The nine −37 photos excluded from
the earlier spatial calibration averaged 0.035012, down from 0.036117.
Shadows −100 improved from 0.022093 to 0.016835 on the gray ramp and from
0.119338 to 0.105434 on the color chart. The −50 prediction itself still
accounts for substantial error. As a diagnostic, supplying the true Lightroom
neutral and −50 endpoints reduced the predicted −37 error to 0.000775 on the
13 paired photos. Normal rendering derives its endpoints from the source image.

On the supplied photograph, isolated Highlights −11 improved from 0.005211
to 0.004721. The five A10 Light controls together measured 0.006212
(previously 0.006200). Against the supplied `processed.tif`, the full set
of implemented effects with grain measured 0.045925 (previously 0.045505).

In the earlier separate-feature comparison on the supplied A10 TIFF, with grain disabled in both Brightroom versions,
full-preset p95 rose from 0.042494 to 0.043393. The intermediate version
which still applied Highlights first measured 0.044080. The combined Light
settings on the photograph rose from 0.007161 to 0.008012, although the
isolated Highlights slider improved. With grain enabled in both versions the
supplied pair rose from 0.047665 to 0.048452. [Grain comparison](grain.md)

### Joint Highlights and Shadows

The joint feature and the wide-gamut positive Shadows calculation below give
the following results with the original signed XMP settings. The four- and
five-control settings also include the other authored Light controls.

| Comparison | Separate stages, previous p95 | Joint feature, current p95 |
|---|---:|---:|
| Color chart, only Highlights −35 and Shadows +42 | 0.072052 | 0.032376 |
| Color chart, −35/+42 with Whites and Blacks | 0.075141 | 0.034245 |
| Color chart, A10 five Light controls | 0.049194 | 0.031238 |
| Photograph, A10 five Light controls | 0.008012 | 0.006200 |
| Same photograph, stronger combined settings | 0.016460 | 0.012457 |
| Supplied TIFF, implemented A10 controls with grain | 0.048452 | 0.045505 |
| Supplied TIFF, same Lightroom reference and Brightroom grain disabled | 0.043393 | 0.039885 |

On the photograph, the response attributable to interaction among A10's five
Light controls differed by p95 0.005852 between engines using the previous
stages and 0.003406 using the joint feature. This measurement subtracts the
sum of each engine's five individual slider changes from its joint change.
It used 375,000 positions on the same 8-pixel grid.
[Fit and reproduction](../Tools/LightroomComparison/Light/README.md#measuring-the-interaction-between-light-sliders)

The current joint feature calibrates the first-stage Shadows lift through the
two public stages in their actual order. At −35/+42, the shadow slider's
effective value is +35.826 and Highlights measures its input at −15.618.
The fit used the original two-control chart. In a darker region of its
linear gray ramp, the mean red channel after the joint edit is 0.1970,
compared with Lightroom's 0.2007 and the previous render's 0.1892.

With both implementations measured against each engine's own neutral in
linear Display P3, the chart p95 changes from 0.020435 to 0.018400.
On the A10 photograph with the five Light controls it changes from
0.005119 to 0.005061. On the same photograph with the stronger five-control
setting it increases from 0.010010 to 0.010168. No photographic outputs
entered the coefficient fit. Other photographs with both sliders active
remain unverified.
[Reproduce the joint calibration](../Tools/LightroomComparison/Light/README.md#measuring-the-interaction-between-light-sliders)

#### Weak Highlights with lifted Shadows

On the five-control A10 chart, the observed changes in linear RGB are best
explained by approximately 19% of the isolated Highlights −11 change and 92%
of the isolated Shadows +30 change. This estimate removes the separate measured
Whites, Blacks and saturation responses from the combined export. On the
two-pair chart, sampling the measured Whites/Blacks table on the actual Lightroom
Highlights/Shadows output gives a p95 error of 0.00055 at −35/+42, −18/+16.

The joint feature reduces the contribution of the weaker slider below the
measured −35/+42 pair, relative to the opposing strength. At −11/+30 it
evaluates Shadows at +27.885, then Highlights at −2.879. Each isolated
slider still has its authored strength across the entire range.

| Same-input comparison | Previous p95 | Current p95 |
|---|---:|---:|
| A10 chart, five Light controls | 0.025774 | 0.021251 |
| A10 photograph, five Light controls | 0.004918 | 0.004151 |
| Same photograph, stronger five-control edit | 0.009580 | 0.009580 |
| Same photograph, implemented A10 preset including grain | 0.044077 | 0.042898 |
| Supplied Apple-developed TIFF and its Lightroom A10 export | 0.043769 | 0.042636 |

The first four rows measure changes from each engine's own neutral. The
last row compares final output pixels directly. All values use the 95th
percentile of the largest absolute RGB-channel difference per pixel in
linear Display P3 on macOS. The two photographic inputs show the same
scene and carry different profiles. Highly saturated colors and the
bright gray ramp still show residual differences in the Light controls.
[Reproduce the two chart measurements](../Tools/LightroomComparison/Light/README.md#weak-highlights-with-lifted-shadows)

The iOS Parametric test target includes 16-bit exports
of the independent color chart and monotonic slider behavior across the
negative Highlights and Shadows anchors. The tests cover flat fields in Float32/Float16 contexts,
neutral and legacy paths, signed spatial dependence, retained Adobe samples,
alpha, the HDR extension, color management, partial renders, and reduced previews.

### Negative Shadows in color

`ShadowsFeature(lightroomAmount:)` and the Shadows stage of
`HighlightsShadowsFeature` share a measured −50 endpoint. Its correction depends
on the source luminance, red and blue relative to luminance, the existing spatial
prediction, and the image-wide distribution of log luminance. Each scene computes
four luminance knots on a 4×4 GPU image. Neutral grays bypass the chroma correction.
The ProPhoto gamut extension supplies the signed −50 color. Stronger Shadows
extrapolates its two extrema in linear ProPhoto RGB using a log-odds coordinate
with a fitted black offset and white headroom. The −10 and −25 color exports
determine the hue-dependent gain at each extremum. The paired −50 and −100
color lattice supplies one further gain proportional to the input's linear-P3
RGB span. It acts on the additional loss at both extrema. Interpolating
the middle component on the source RGB line preserves hue. Limiting the total
loss to the available room above ProPhoto black keeps the slider monotone after export.

The −50 calibration used nine photographs, four color layouts and one 32³ color
lattice. On nine other photographs at −32, the mean per-image p95 RGB error fell
from 0.012460 to 0.011857 on macOS and from 0.012504 to 0.011878 on the iOS
simulator. Eight photographs improved. The boat photograph increased from
0.004727 to 0.006493 on macOS. On the full chart at −100, the new strong
interval reduced p95 from 0.071051 to 0.069025. Across the 32,768 distinct color
codes it fell from 0.075741 to 0.057502. The 2,048 saturated cyan codes improved
from 0.102871 to 0.031540. The eight brightest cyan patches retained mean green
of 0.980 on macOS and 0.976 on the iOS simulator, against 0.982 in Lightroom.
The color lattice in that measurement had a maximum RGB error of 0.332.
[Calibration, metrics and reproduction](../Tools/LightroomComparison/Light/README.md#shadow-color-response)

The later strong-interval calibration was checked against four developed
photographs at −100. On macOS in half precision, the full-chart response p95
changed from 0.055478 to 0.054552. The p95 of the change from −50 to −100
went from 0.030383 to 0.026635. The four photographs' mean −100 response
p95 moved from 0.022409 to 0.022384. The boat increased from 0.019803 to
0.019817. In single precision, the full-chart −100 p95 increased from
0.053300 to 0.053626 while the interval p95 fell from 0.029154 to 0.026222.
[Strong Shadows color calibration](../Tools/LightroomComparison/Light/README.md#strong-negative-shadows)

### Negative Shadows in detailed scenes

At −50 the feature estimates how much luminance a given source tone loses
across the image. On the existing 256-pixel analysis guide, it samples 2,048
positions and collects the predicted loss in 128 overlapping luminance bins.
The full-resolution pass uses this estimate where the input has fine detail
and the bin has enough samples. In a dark neighborhood it increases the
estimated loss according to the local and image-wide shadow coverage. Broad
dark regions and smooth gradients retain more of the spatial response. All
negative strengths use this corrected endpoint. The public XMP value and the
source image provide all inputs.

The fit used −50 measurements from nine photographs and 24 synthetic images.
On macOS in half-float, the mean per-photo p95 RGB error fell from 0.016318
to 0.013202 on the nine photographs. At −32, six of nine separate photographs
improved and the mean fell from 0.011371 to 0.010599. The boat increased
from 0.006541 to 0.008224. At −100 the color lattice improved from 0.068401
to 0.055952. The following photographic acquisition tested the same update at −100.

The spatial diagnostic measures the difference between two locations that
have identical source RGB. On the bridge at −32, the p95 discrepancy from
Lightroom fell from 0.013162 to 0.000805 across 4,980 such pairs. The
black-and-white portrait at −50 retains a discrepancy of 0.041568 across
211 pairs. Its Lightroom response varies substantially with position.
[Spatial comparison procedure](../Tools/LightroomComparison/Light/README.md#spatial-variation-at-identical-source-colors)

## Comparison loop

Use `A10/run.py --modes tonal adaptive` to compare old H/S with the spatial
features. Both modes use the current public Whites/Blacks and measured Mixer.
Use `--scope partial --modes adaptive` against `user-a10-authored-002` for the supplied
A10 pair. See [the Light procedure](../Tools/LightroomComparison/Light/README.md)
for acquisition, fitting, exact commands, and known discarded hypotheses.

### Positive Shadows

At small positive amounts the response depends on the input tone. On the
reference ramp, an encoded gray near 1/8 received 16% of its +50 lift at +10.
A gray near 5/8 received 20%. Nine samples of the +10 and +25 ramps determine
the strength between zero and +50.

The +50 endpoint also corrects RGB chroma at constant linear Display-P3
luminance. One RGB cube and four synthetic layouts supply three coefficients
for the change in RGB span. Interpolation to that endpoint preserves the hue
and the direction of the lift. Above +50 the additional spatial adjustment
continues from that endpoint. In the two reserved color layouts, the mean
+50 p95 fell from 0.016338 to 0.009461. The five +17 photographs averaged
0.008424. The +100 color cube measured 0.137389 at that stage.

The current positive Shadows calculation uses the minimum and maximum
channels of the pixel in linear ProPhoto RGB to select the endpoint lifts.
It maps those lifts onto the original Display-P3 color axis. Above +50,
colors extending past the ProPhoto endpoints use the nearest endpoint's
additional lift, so advancing the slider continues to lift saturated reds.
Luminance and the spatial guides are still measured in linear Display-P3.
All 33 measured grayscale settings retained identical output pixels.

On the RGB chart, +30 p95 fell from 0.038002 to 0.029666, +50 from 0.062452
to 0.051871, and +100 from 0.137389 to 0.114052. Two reserved +50 color
layouts averaged 0.008243, down from 0.009461. The five +17 photographs
averaged 0.008349, down from 0.008424. Three improved. Two went from
0.003630 to 0.004491 and 0.005399 to 0.005412.
[Calibration and reproduction](../Tools/LightroomComparison/Light/README.md#global-saturation-and-positive-shadows)

### Source-color neighborhoods for negative Light

Negative Highlights and Shadows measure the linear luminance change at −50
on a nearest-sampled grid with a long edge of at most 256 pixels. Each guide
pixel compares that change with eight directions at four distances, weighted
by proximity in encoded Display-P3 color and by alpha. The full-resolution
pixel receives the resulting adjustment before its measured strength curve
and gamut limits. It therefore uses the same spatial measurement across the
slider. Highlights converts the luminance change to each RGB extremum in
proportion to the local transfer-function slope. Shadows evaluates its
response at the pixel's luminance.

On macOS half-float exports, mean per-image p95 fell from 0.043003 to 0.040631
on four held-out photographs at Highlights −50, from 0.024916 to 0.023491 on
nine at Highlights −37, and from 0.011857 to 0.011371 on nine at Shadows −32.
At Highlights −37, three of those nine photographs had higher p95.
The original 32³ color chart improved at −50 and −100 for both controls.
Its Highlights −10 and −25 p95 increased by 0.000101 and 0.000160.
[Measurements and reproduction](../Tools/LightroomComparison/Light/README.md#source-color-neighborhoods)

### Negative Highlights across slider strengths

The Highlights guide also measures how often the brightest encoded Display P3
channel in its surroundings is brighter or darker than the center pixel. It
measures the nearer two distances and the farther two separately. Three source
luminance knots convert those four coverages into a luminance adjustment and
a change in the RGB span about that luminance. A transparent neighbor
contributes in proportion to its alpha.

Colored pixels have both a spatial estimate of the −50 peak and a color-corrected
estimate. Their difference relative to the final peak loss sets how much of
the calibrated strength curve to use. Its −10 anchor uses the first nonzero
measurement of the original slider sweep. The rest of the adjustment follows
each channel's remaining progress from −10 toward −50. All of these weights
come from the input and the fixed anchors.

On the same 13 photographs, macOS half-float mean per-image p95 improved from
0.029081 to 0.027458 at −37 and from 0.037992 to 0.037183 at −50. Eleven
photographs improved at each strength. Nine contributed to calibration, and
four supplied a separate check of both strengths. Across nine photographs
outside calibration at −37, p95 went from 0.023491 to 0.022388. The original
32³ chart improved at −10, −25 and −50. Its −100 p95 increased from 0.082563
to 0.083355. [Calibration and reproduction](../Tools/LightroomComparison/Light/README.md#negative-highlights-peak-coverage)

### Strong negative Highlights

At strengths below −50, the feature estimates the additional loss in the
lightest and darkest channels. The fixed spatial estimate, the −50 response
and the source chroma determine the endpoint. Between −50 and −100, the
endpoints follow the ProPhoto log-odds interval measured on the two charts.
For colors near P3 black, the calibrated spatial endpoint supplies the peak
used in the final color projection.

The coefficients were fitted using Adobe measurements through −50 on 34
inputs. The four photographs in this comparison were excluded from the fit.
On macOS in half-float, their mean per-image p95 improved from 0.085844 to
0.075839 at −100 and from 0.059539 to 0.058173 at −75. Three photographs
improved at −100 and two at −75. The original color lattice at −100 improved
from 0.083355 to 0.061286 and the gray ramp from 0.057219 to 0.039865.
Both charts contributed weaker settings to the fit. At −75 the photographs'
mean p99 rose from 0.088118 to 0.090154.
[Fit and signed-XMP comparison](../Tools/LightroomComparison/Light/README.md#strong-negative-highlights)

The spatial portion of the −50 to −100 Highlights interval also uses the
scene's log-luminance spread, the fraction of variance removed by the first
blur, and the broad neighborhood's spread relative to the scene. The gain
acts before the textured-gray estimate and the ProPhoto gamut limits. The
neutral, −50 and −100 exports of a gray ramp, a color lattice, a sign and a
bridge determined its coefficients. A boat and a plant provided separate
checks at −75 and −100.

On those two evaluation photographs, the macOS half-float renderer's
mean response p95 at −100 decreased from 0.03520 to 0.03300. The four
photographs improved at both strengths on macOS and the iOS simulator.
The original lattice at −100 improved in both half-float configurations.
Its single-precision macOS response p95 increased by 0.00079.
[Measurement and calibration](../Tools/LightroomComparison/Light/README.md#measuring-the-strong-highlights-interval)

### Same input luminance in different parts of a scene

Negative Highlights computes a second estimate of the −50 loss from up to
2,048 samples of its GPU guide. For each of 128 encoded luminance intervals,
it accumulates the pilot's linear-P3 luminance loss and sample weight.
At full resolution it moves the local loss toward the mean for that tone by
up to 52.5%. To lift a region the local model has darkened too much, it
requires stronger evidence of image detail, measured by the fraction of
log-luminance variance removed by the smallest blur. Rare tones and colors
near the P3 gamut limit give less weight to the scene mean.

When the scene mean would cause extra darkening, the shift toward that mean
is reduced by up to half for pixels brighter than their immediate neighborhood.
The comparison uses the four-pixel guide at a 1024-pixel long edge and the
image's log-luminance standard deviation. All four radii, both contrast
directions, and lifting and darkening were measured at −50.

At −50 the minimum and maximum RGB channels receive the same shift. Weaker
settings take each channel's fractional progress toward its −50 response.
Stronger settings start at the adjusted −50 endpoint. The public XMP units and
the feature's zero bypass are unchanged.

In the macOS half-float renderer, the mean response p95 on 13 photographs at
−50 went from 0.035276 to 0.032086. All four photographs excluded from this
fit improved at −50 on macOS and on the iOS simulator. The
original color lattice improved at −100 in all three tested configurations.
On a bridge photograph the sky was still too dark next to a tower. At source
luminance 0.55 ± 0.005, the closest measured band was darker than before,
while both more distant bands moved closer to Lightroom.
[Measurements and reproduction](../Tools/LightroomComparison/Light/README.md#negative-highlights-at-the-same-input-luminance)

### Negative Highlights in a dark surround

The four-pixel guide also measures the average distance below 0.5 in encoded
P3 luminance. A pixel retains some of its original color when that distance
exceeds the pixel's own distance below 0.5. The weight increases with the
span of the source RGB channels and tapers near the P3 gamut limit. Neutral
pixels receive a smaller correction when the whole scene is dark. These
weights were fitted at −50 on 34 distinct inputs.

The correction starts after the measured −25 anchor. Between −25 and −50 it
follows the additional loss in each channel. At stronger settings the same
corrected −50 color feeds the existing strong-response curve. The GPU reads
the statistics already available to the feature.

In a macOS half-float export, mean response p95 at −50 fell from 0.032086 to
0.030052 on 13 photographs. On four photographs at −100 it fell from
0.060443 to 0.057663. The largest improvement was on the sign. Bright sky on
the bridge still darkened too much, and the boat and plant had small increases
in full-image error. On the original color lattice, −100 improved on macOS in
both working formats and on the iOS simulator.
[Calibration and comparisons](../Tools/LightroomComparison/Light/README.md#negative-highlights-in-dark-surroundings)

## Strong negative Shadows on photographs

The macOS renderer saved the outputs of both implementations on four photographs
before acquiring their Lightroom Shadows −100 exports. The figures below measure
the change from each engine's matching neutral in linear Display P3. Each entry
is the 95th percentile of the largest absolute RGB-channel error per pixel.

| Photograph | Previous response | Current response |
| --- | ---: | ---: |
| Sign | 0.024508 | 0.023589 |
| Bridge | 0.042280 | 0.024962 |
| Boat | 0.016750 | 0.021268 |
| Plant | 0.038007 | 0.033005 |
| Mean | 0.030387 | 0.025706 |

For the boat's 126,973 pixels with neutral luminance from 0.05 to 0.18,
Lightroom's mean change was −0.024142. The previous implementation produced
−0.026191 and the current one −0.028015. The current response is closer in
brighter bands. These four photographs provide new evidence for the already
implemented Shadows adjustment. [Acquisition and replay](../Tools/LightroomComparison/A10/README.md#measure-presence-and-dehaze)

### Negative Shadows at the scene's middle tone

At −50, `ShadowsFeature(lightroomAmount:)` also reads the loss at the
geometric mean of the scene luminance from its 128-bin table. Up to a quarter
of that loss contributes to the pixel's estimate. The share fades above the
middle tone and falls to zero when half of the sampled scene already
contributes to the pixel's own tone. The same estimate feeds the negative
Shadows stage of `HighlightsShadowsFeature`.

At weaker settings the local spatial curve supplies the fraction of darkening
over its own −50 change. If the corrected endpoint darkens the pixel further,
that additional loss grows in proportion to the slider. This avoids applying a
large −50 correction at −10 when the local curve has very little change to measure.

On the nine calibration photographs, the mean response p95 at −50 fell from
0.013210 to 0.012797 in the macOS half-float renderer. On a separate nine at
−32 it fell from 0.010593 to 0.010162. At −100 the plant improved from
0.033006 to 0.022645 and the boat from 0.021268 to 0.021198. The sign and
bridge increased by 0.000124 and 0.000748 respectively. On the boat, the
largest improvement occurs above linear luminance 0.25. The darkest band
still loses more light than in Lightroom.

Using the actual Lightroom −32 response to predict −100 gave p95 errors of
0.00084–0.00278 on the four photographs. This calculation isolates the
strength interval from the estimate of the initial loss. The product computes
its response from the input image alone.
[Same-source interval measurement](../Tools/LightroomComparison/Light/README.md#comparing-two-negative-shadows-settings-on-the-same-photograph)

### Dark tones beside a brighter region

At negative Shadows settings, the dark side of a bright edge can retain more
light than a similar input tone farther inside the dark region. The feature
compares each pixel's log luminance with the mean on its existing four-pixel
Gaussian guide (radius per 1024 pixels of long edge). The signed difference
adjusts the −50 endpoint. One term gives more weight to the darkest tones,
and another gives more weight to low-variance neighborhoods. Both fade out
between 0.18 and 0.45 in encoded P3 luminance. The existing strength curve
uses this endpoint for both weaker and stronger settings.

The correction scales the RGB loss together and keeps the corrected extrema
ordered and inside the available black and source levels. It reuses the same
GPU samples as the spatial response. The two coefficients were fitted on
nine photographs, 24 synthetic scenes and the color lattice at −50. On a
separate nine photographs at −32, the macOS half-float mean response p95 fell
from 0.010162 to 0.009959. At −100 it fell from 0.023317 to 0.022409 on four
of those photographs. The color lattice increased from 0.055428 to 0.055478
at −100.

On the boat photograph at −100, pixels with input luminance 0.045–0.055
within 4–16 pixels of a bright region still lost too much light. The median
excess loss fell from 0.01519 to 0.01315 in linear Display P3. The fit
approximates the observed response. The measurements leave Lightroom's
internal choice of neighborhood unresolved.
[Measure distance from a bright region and reproduce the fit](../Tools/LightroomComparison/Light/README.md#negative-shadows-near-bright-regions)

### Bright tones near the top of a scene's range

At negative Highlights settings, a large area of nearly uniform sky can lose
too much light even when the −50 to −100 response is close to the measured
strength curve. The feature estimates the −50 loss at two other source tones,
0.09 darker and brighter in encoded Display P3 luminance. Each has its own
frequency and measured loss in the existing GPU scene table. The calibrated
odds response expresses both losses at the pixel's own luminance.

The estimate receives more weight in smooth scenes and at a well-represented
bright tone with fewer samples above it. A sparse or absent neighboring tone
contributes less. The square root of the ratio between the lowest and highest
color channels reduces the correction on saturated colors, where a luminance
bin conveys less information about a secondary channel. The same −50 shift
scales through the existing weaker and stronger intervals. The GPU uses two
additional reads from the scene table per adjusted pixel.

The bin spacing was selected on Highlights −50. The amount and its dependence
on color were checked on nine photographs, 24 synthetic spatial charts and
one color lattice. The bridge, sign, boat and plant were excluded from that
calibration. The [native comparisons and fitting command](../Tools/LightroomComparison/Light/README.md#negative-highlights-across-neighboring-luminance-bins)
record the settings and inputs.

### Positive Shadows in colored regions

The positive branch measures the image-wide standard deviation of log luminance
and the difference between two geometric means of luminance, one from the
64-pixel Gaussian guide and one from the whole image. The guide radius scales
with image size. Four input-luminance knots map these measurements to the rate
of lift at +50. Each step in slider strength multiplies the ratio of distances
to black and white in linear ProPhoto RGB. A common rate moves both ProPhoto
extrema, with interpolation along the original RGB hue line. For highly colored
pixels this estimate receives more weight. A bright component also retains a
fraction of its spatial lift when the pixel's luminance lies near that component.
Neutral grays continue to use the measured spatial ramp.

The coefficients came from 25 gray inputs, four color layouts and the 32³ color
lattice at +50. Five separately registered +17 photographs all improved on
macOS. Their mean response p95 went from 0.008360 to 0.007431. At +30 the
24-megapixel reference photograph went from 0.006088 to 0.004831. The full
color chart at +100 went from 0.114039 to 0.099640. One reserved +50 color
layout went from 0.007470 to 0.008181. Positive Shadows above +50 has been
compared to Lightroom on charts; a same-input photographic +100 reference
remains to be acquired. These are linear Display-P3 changes relative to each
renderer’s neutral output.

[Calibration and comparison procedure](../Tools/LightroomComparison/Light/README.md#regional-lift-for-positive-shadows)

Negative Highlights uses local contrast to refine the loss of saturated colors.
The radius-4 guide compares the source pixel with its immediate surroundings.
The radius-64 guide compares the surrounding region with the scene. At −50,
each linear ProPhoto component takes its own share of the resulting luminance
shift. Stronger values scale the extra loss from the same −50 color. The
weight fades near the P3 black boundary, where there is a separate wider-gamut
calibration. These calculations use the existing guides and the original XMP
amount. [Calibration and photographic evaluation](../Tools/LightroomComparison/Light/README.md#local-contrast-in-negative-highlights)

### Metering negative Highlights from the scene's bright tones

On a developed image, lowering Highlights can affect two pixels of the same
luminance differently. In the bridge photograph, much of the sky occupies a
narrow range below white. At −50 the previous response darkened that range
too much. On the boat photograph the sign of the error also varied with the
surrounding brightness.

The negative branch measures the 25th, 75th, 95th and 98th percentiles of
encoded P3 luminance in the alpha-weighted scene histogram. One additional
GPU texel holds the 95th percentile, the 98th-to-75th percentile spread,
and the amount of midtone loss to retain. Each output pixel compares its log luminance with the
existing radius-4 and radius-64 guides. Higher local variance reduces the
contribution of that neighborhood. The resulting gain adjusts the loss at
−50. The same endpoint drives weaker and stronger slider values.

Nine photographs, 24 spatial charts and a color lattice supplied the four
metering coefficients at −50. A lift toward the source is shared according
to each endpoint's loss, and a drop toward black according to each
endpoint's remaining light. The weighted change gives the requested
luminance shift. A channel at black no longer prevents another channel
from darkening. Weaker slider settings take the fraction of that shift
corresponding to each channel's progress toward −50.
[Refit the metering coefficients](../Tools/LightroomComparison/Light/README.md#negative-highlights-scene-range)

On the bicycle and bridge photographs, the previous −50 estimate darkened
midtones too much. For interquartile ranges wider than 0.45 encoded units,
the remaining midtone loss now decreases in proportion to the excess range.
Two strips at opposite ends of the histogram can also produce a wide
interquartile range. The overlap between the scene histogram and a uniform
histogram reduces the adjustment when few intermediate tones are present.
Fine detail supplies a further weight. Smooth ramps receive little change.
These cutoffs are empirical. [Reproduce the paired −50, −75 and −100 measurements](../Tools/LightroomComparison/Light/README.md#measuring-the-strong-highlights-interval)

### Color at the edge of Display P3

The full-resolution pass resolves color after applying the local luminance
correction. In the interior of the gamut it estimates the separation of
the two linear ProPhoto extrema at that luminance. Near the P3 black
boundary it uses the adjusted ProPhoto peak to recover the lower channel
with the same change in odds. The middle channel stays on the source hue
line, which allows a component of the output to fall below P3 black.

At Highlights −25 the registered blue patches lose 0.02642 linear P3 red
in Lightroom. The iOS half-float output moved from 0.00957 to 0.02039.
On macOS the mean paired RGB p95 at −100 on four photographs moved from
0.05109 to 0.04981. The largest residual was the bridge at 0.07417.
At −37 one of the 13 photographs regressed from 0.01413 to 0.01702.
[Compare color changes at equal input luminance](../Tools/LightroomComparison/Light/README.md#color-at-equal-source-luminance)

### Negative Shadows beside a brighter region

A gray ramp surrounded by 98% encoded gray loses less light at its boundary
in Lightroom than in the previous spatial model. Negative Shadows now uses
the positive difference between the region's encoded geometric-mean luminance
and the center pixel's encoded luminance. The region uses the existing
Gaussian guide of radius 16 pixels at a 1024-pixel long edge. The feature
returns a fraction of the predicted RGB loss proportional to that difference.
The same fraction applies at every negative strength, preserving the slope
direction as the slider moves.

For the 512 middle-gray ramp samples directly beside the bright surround,
the paired mean green-channel loss at −50 was 0.068742 in Lightroom.
The public feature on macOS moved from 0.080059 to 0.077105. On the complete
32³ chart with its gray strip, response p95 at −100 moved from 0.051470 to
0.051393. Across four photos excluded from coefficient fitting, mean p95 at
−100 moved from 0.021589 to 0.021384. The boat improved from 0.019314 to
0.018508 and the illuminated sign increased from 0.021765 to 0.021902.
These photos were inspected when choosing between candidate models.
[Calibration and replay](../Tools/LightroomComparison/Light/README.md#negative-shadows-beside-a-brighter-region)

### Negative Highlights across neighborhood sizes

`HighlightsFeature(lightroomAmount:)` also measures where a pixel falls
within four differently sized neighborhoods. A gray patch between dark
strips and a similarly bright patch in a detailed photograph can need
different changes in brightness. The feature uses the existing Gaussian
guides, smooths each rank over five percentage points of encoded luminance,
and scales the existing loss by the same fraction at every slider strength.
Near the P3 gamut boundary the existing peak-channel response receives
more weight. This keeps the blue component of saturated cyans close to its
measured value.

On nine photographs and 24 spatial charts the weights were fitted at −50,
with the color half of a separate lattice included. On four other photos
at −100, macOS half-float mean response p95 moved from 0.047204 to 0.045604.
The sign went from 0.064959 to 0.059637, the bridge from 0.063736 to
0.063535, the boat from 0.044391 to 0.042810 and the plant from 0.015731
to 0.016433. We inspected these four photos during model selection.
The −50-to−100 interval on the same four had a mean p95 of 0.024120 before
and 0.024148 after. On the supplied 24-megapixel A10 photograph the absolute
p95 moved from 0.043677 to 0.043769.
[Reproduce the fit and render signed XMPs](../Tools/LightroomComparison/Light/README.md#negative-highlights-at-different-neighborhood-sizes)

### Negative Highlights at a peak in the scene histogram

At −50 the estimated luminance loss also depends on how many source pixels
share that tone. The feature compares the population of the current tone
with the populations 0.09 encoded P3 luminance units below and above it.
A peak above the darker bin retains some of the spatial estimate's loss.
A peak above the brighter bin increases the loss. Each contribution tapers
as its neighboring bin runs out of samples. This keeps an endpoint of a
limited-range ramp from acquiring the response of a populated interior
tone. The contribution also tapers toward white, in proportion to squared
encoded headroom. The same two neighboring histogram reads serve both the
density measurement and the existing estimate of neighboring luminance loss.

The two gains come from −50 pairs for nine photographs, 24 spatial charts
and the colored half of a lattice. Four other photographs helped evaluate
the choice of model. On those four, mean signed-response p95 at −100 moved
from 0.045604 to 0.043442 on macOS and from 0.048180 to 0.045766 on the
iOS simulator in half-float. The bridge accounted for most of the improvement.
The plant and the full color lattice regressed slightly at −100. Applying
A10 to the supplied common TIFF moved absolute p95 from 0.042636 to 0.042610.
[Calibrate from registered reference pairs](../Tools/LightroomComparison/Light/README.md#negative-highlights-at-a-peak-in-the-scene-histogram)
