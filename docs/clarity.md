# Clarity on developed RGB

`ClarityFeature(amount:)` accepts Camera Raw's signed `Clarity2012` slider directly.
Zero bypasses the effect. The public validating initializer accepts finite values from −100 to 100.

```swift
let clarity = ClarityFeature(amount: 4)
let result = try FeatureRenderer().makeImage(from: developedImage, feature: clarity)
```

The feature measures how far the encoded luminance of each pixel lies above or below
its neighborhood average. A second blur measures the mean magnitude of those
differences. Negative Clarity also uses their signed mean to distinguish the
lighter and darker sides of an edge. Both neighborhoods weight samples by opacity and operate on a guide
of at most 1024 pixels on the long edge. The output adjusts the full-resolution
linear Display P3 color along its original hue direction. The brightness and
color responses interpolate between measured slider settings at −100, −50, 0,
+4, +50 and +100. Other slider values have no independent Adobe reference in this study.

## Measurements

The references are Lightroom Classic Process Version 15.4 exports of the same
developed RGB input at 16 bits, in ProPhoto RGB. A 32³ color lattice and two
photographs (a sign and a bridge) supplied the coefficients. A boat and a plant
were reserved for evaluation before collecting the Lightroom exports. Each
number below is the mean of those two photographs' separate 95th percentiles.
The error uses the largest absolute RGB component of each pixel's difference
in adjustment response, in linear Display P3 with diffuse white at 1.

| Clarity | With Clarity omitted | With the public feature |
| ---: | ---: | ---: |
| −100 | 0.123347 | 0.046895 |
| −50 | 0.071714 | 0.027604 |
| +4 | 0.004881 | 0.004121 |
| +50 | 0.057912 | 0.049131 |
| +100 | 0.110639 | 0.096219 |

The signed mean reduced macOS p95 in all ten negative cases. Before adding
it, the two evaluation photos averaged 0.053449 at −100 and 0.031484 at −50.
On the iOS simulator these means went from 0.053683 to 0.047173 and 0.031612 to
0.027761. These two photos were also used to decide to retain the additional
guide only at negative strengths.

All 25 nonzero settings reduced response error relative to omitting Clarity on both macOS and the iOS
simulator. Strong positive Clarity retains the largest errors on the held-out
photos. At +100 the boat's p95 was 0.12140. The supplied 24-megapixel photograph's
full A10 absolute p95 moved from 0.044484 with Clarity omitted to 0.044253 with
Clarity +4. That comparison predates Texture support. The current adapters apply
Texture, Clarity and Dehaze, in that order, after the point curve.
[Calibration and comparison procedure](../Tools/LightroomComparison/A10/README.md#reproduce-the-clarity-response)
