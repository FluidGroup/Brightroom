# Grain

`GrainFeature` authors amount, `EffectRadius`, roughness and seed.
Its texture is anchored to image coordinates; the context supplies spatial
scale and frame time. A nonzero adjustment requires a finite chain-entry extent.

`GrainFeature.CameraRaw` retains amount, size and roughness in 0…100 and a
`UInt32` seed. Its lightweight standard calculation delegates to ordinary Grain
with full-resolution radius `size / 25`. This delegation explicitly uses
standard adjustments, not a separately installed ordinary-Grain replacement.
Amount zero is neutral and does not discard the other authored parameters.

These are lightweight standard calculations, not Lightroom-fitted responses.
Install a provider through [Feature implementation setup](adjustment-rendering.md)
to replace the calculation without changing authored values or history.
