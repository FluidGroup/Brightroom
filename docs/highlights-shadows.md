# Highlights and shadows

`HighlightsFeature` and `ShadowsFeature` use normalized recovery/lift values.
The standard recipes use Core Image highlight/shadow controls.

`HighlightsShadowsFeature(highlights:shadows:)` accepts two signed −100…100
amounts. Its standard body applies Shadows then Highlights. A registered
compound implementation receives both original amounts before decomposition.
Zero is neutral; the Feature values contain no implementation selector.

These are lightweight standard calculations, not Lightroom-fitted responses.
Install a provider through [Feature implementation setup](adjustment-rendering.md)
to replace the calculation without changing authored values or history.
