# Texture on developed RGB

Pass the signed Camera Raw `Texture` setting directly to `TextureFeature`. It accepts −100 through +100. Zero returns the source image. The validating initializer rejects nonfinite and out-of-range values.

```swift
let texture = TextureFeature(amount: 4)
let adjusted = try FeatureRenderer().makeImage(from: developedImage, feature: texture)
```

The feature increases local RGB contrast at positive strengths and reduces it at negative strengths. It compares each encoded component with its Gaussian neighborhood and attenuates the change in areas of high contrast. At low contrast the gain is bounded by the strongest response measured on a chart of sinusoidal stripes. This preserves stripe polarity when softening. The neighborhood radius is 12 full-resolution pixels and scales with the preview. Two opacity-weighted averages give the mean and variance. When the rendered radius is at least six pixels, these averages run at half width and height. The center pixel and the output keep their original resolution. The adjustment uses ROMM RGB primaries with a Display P3 transfer curve, applies the resulting color difference to the original linear RGB, and preserves alpha.

## Measurements

The comparison used identical developed inputs and 16-bit ProPhoto RGB Lightroom Classic exports at Process Version 15.4. A color lattice, a chart of gray sinusoids, a sign and a bridge supplied the coefficients. A boat and a plant were set aside before acquisition. Each result below is the mean of their separate 95th percentiles. For each pixel, the error is the largest absolute RGB component of the difference between each engine's edit and its own neutral, in linear Display P3 with white at 1.

| Texture | Omitted | macOS | iOS simulator |
| ---: | ---: | ---: | ---: |
| −100 | 0.061359 | 0.016852 | 0.016936 |
| −50 | 0.037248 | 0.010167 | 0.010212 |
| +4 | 0.004678 | 0.001341 | 0.001354 |
| +50 | 0.045402 | 0.012583 | 0.012663 |
| +100 | 0.071677 | 0.019823 | 0.019958 |

The seven inputs produced 38 registered cases, including seven neutrals. All 31 nonzero cases improved over omitting Texture on both platforms. Additional strengths interpolate through zero and the five measured endpoints.

At +50, Lightroom amplified a 16-pixel-period sinusoid centered on encoded gray 0.5 by 46% at amplitude 0.035 and 15% at amplitude 0.18. Repeating the narrow chart twice across a wider canvas changed both values by less than one percentage point. Brightroom amplified the same two patches by 51% and 21%. At −100, Lightroom reduced the weak patch's contrast by 63% and Brightroom reduced it by 69%. The remaining differences vary with spatial frequency and the amplitude of the input. The Adobe Texture team's description also discusses spatial frequencies. [Adobe's Texture engineering article](https://blog.adobe.com/en/publish/2019/05/14/from-the-acr-team-introducing-the-texture-control)

On the supplied 24-megapixel TIFF, adding Texture +4 to the full A10 edit moved absolute p95 from 0.043755 to 0.043677. A prototype with unbounded gains reached 0.043657 on that photograph and inverted some weak stripes at −100. The bounded response preserved their polarity and improved or tied all 31 individual cases on both platforms. The adapters apply Texture before Clarity and Dehaze. [Reproduce the signed Texture comparison](../Tools/LightroomComparison/A10/README.md#reproduce-the-texture-response)
