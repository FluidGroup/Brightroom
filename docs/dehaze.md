# Dehaze

`DehazeFeature(amount:)` accepts −100…100; zero is neutral.
The standard recipe uses Core Image color controls with contrast
`1 + 0.5 * amount / 100` and saturation `1 + 0.1 * amount / 100`.
It preserves input extent and does not load a calibrated scene model.

These are lightweight standard calculations, not Lightroom-fitted responses.
Install a provider through [Feature implementation setup](adjustment-rendering.md)
to replace the calculation without changing authored values or history.
