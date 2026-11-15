# Point curves

`PointCurveFeature` applies a master curve followed by independent RGB curves.
`ToneCurve` accepts 2…12 points with finite coordinates in 0…1 and at least
0.02 spacing on the input axis. Apps own persistence and reconstruct values
through validating initializers.

```swift
let master = ToneCurve(validating: [
  .init(input: 0, output: 0),
  .init(input: 0.5, output: 0.6),
  .init(input: 1, output: 1),
])!
let effect = PointCurveFeature(curves: .init(master: master), refineSaturation: 50)
```

The standard implementation uses natural cubic splines and generated sampling
strips, not frozen calibration data. `refineSaturation` ranges from 0…100;
master processing precedes the RGB curves. Identity returns the input itself.
Alpha and extent are preserved, with unit-slope continuation outside the bounded
working domain. `ToneCurveFeature` remains the separate stop-domain/PCHIP shaper.

Lightroom comparison measurements and research procedures belong to
[GradingKit](https://github.com/FluidGroup/BrightroomGradingKit), not the standard
implementation's contract.
