# Texture

`TextureFeature(amount:)` accepts −100…100; zero is neutral.
The standard calculation enhances or softens detail against a Gaussian
neighborhood with a 12-full-resolution-pixel radius, scaled for preview.

These are lightweight standard calculations, not Lightroom-fitted responses.
Install a provider through [Feature implementation setup](adjustment-rendering.md)
to replace the calculation without changing authored values or history.
