# Color Space Test Images

These images are deterministic probes for checking whether a rendering path
honors embedded image color spaces.

The three PNGs use the same 8-bit RGBA sample values but different embedded
profiles:

- `colorspace-probe-srgb.png`
- `colorspace-probe-display-p3.png`
- `colorspace-probe-adobe-rgb-1998.png`
- `colorspace-p3-hidden-text.png`
- `colorspace-p3-hidden-text-srgb-clipped-reference.png`
- `colorspace-gamut-map-display-p3.png`
- `colorspace-gamut-map-srgb-clipped-reference.png`

On a color-managed P3 display, the Display P3 and Adobe RGB versions should not
look identical to the sRGB version in high-chroma patches. If they do, the
viewer likely ignores the embedded profile or collapses everything into the
same untagged destination.

`colorspace-p3-hidden-text.png` is the quick visual check. Its panel
backgrounds are sRGB pure red/green converted into Display P3 component values,
while the hidden letters are pure Display P3 red/green. On a correctly managed
P3 display, the letters should appear through saturation difference. If the
image is flattened to sRGB, the letters should nearly disappear. The
`*-srgb-clipped-reference.png` file shows that flattened result.

`colorspace-gamut-map-display-p3.png` is a visual gamut map. It plots a rough
CIE xy background, overlays the sRGB triangle in red, the Display P3 triangle in
blue, and marks D65. The clipped reference shows what the same image looks like
after an sRGB output conversion.

Regenerate the files with:

```sh
swift Dev/Resources/ColorSpaceTestImages/generate_color_space_test_images.swift
```
