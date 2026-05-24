# EditingStack Local Adjustment Viewport Preview Specification

## Status

Draft for the Metal Brush Sandbox v1.

This document defines the target behavior for a zoomable viewport-rendered
preview that displays an `EditingStack` result and adds local adjustment layers
with a brush mask. Earlier experiments treated a committed tile grid as the
primary display architecture, but the current direction is to make a cached
viewport renderer the interactive main path.

The first production candidate is still the Sandbox. PixelEditor and PhotosCrop
integration should wait until the rendering, preview-purpose, and coordinate
contracts are stable.

## References

- Apple Core Image: `CIImage.insertingIntermediate()`
  https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate()
- Apple Core Image: `CIImage.insertingIntermediate(cache:)`
  https://developer.apple.com/documentation/coreimage/ciimage/insertingintermediate(cache:)
- Apple Core Image: `CIImage.insertingTiledIntermediate()`
  https://developer.apple.com/documentation/coreimage/ciimage/insertingtiledintermediate()
- Apple Core Image: `CIImage`
  https://developer.apple.com/documentation/coreimage/ciimage
- Apple Core Image: `CIContext`
  https://developer.apple.com/documentation/coreimage/cicontext

## Product Goal

Build a Lightroom / Photoshop-like local adjustment preview:

- A user can freely zoom and pan the edited image.
- Global filters are visible everywhere.
- A brush stroke can add a local adjustment layer.
- Local adjustment effects are not limited to Gaussian blur; the renderer must
  be able to compare radius-based effects and non-radius per-pixel effects.
- The local mask is non-destructive and stored in orientation-up original image
  pixel coordinates, not crop-space coordinates.
- The interactive preview should primarily render the visible viewport from a
  viewport-sized cached source texture.
- The live brush layer previews the active local adjustment without waiting for
  slow full-image or tile-grid rasterization.
- The interaction target is Apple Photos Edit quality: large images should feel
  inspectable and editable, not merely loadable.

The committed tile path is no longer the preferred interactive display path.
Tiles may still be useful as a later high-quality still-state cache, but they
should not be required for slider, brush, pan, or zoom responsiveness.

## Benchmark Image Target

The preview should comfortably handle NASA's VIIRS Blue Marble image:

```text
URL: https://eoimages.gsfc.nasa.gov/images/imagerecords/78000/78314/VIIRS_3Feb2012_lrg.jpg
Compressed JPEG size: about 20 MB
Pixel size: 12000 x 12000
Decoded BGRA/RGBA size: 576,000,000 bytes, about 549 MiB
```

This image is the target scale for the architecture. A single full-resolution
decoded bitmap is already too large to treat as a routine interactive buffer,
and multiple full-resolution intermediates are not acceptable. The interactive
preview must therefore be viewport- and level-of-detail-driven.

Apple Photos Edit handles this class of image comfortably, so this benchmark is
not an aspirational stress case. It represents the baseline user expectation for
a native iOS photo editor. If Brightroom needs to show a degraded path for this
image, that should be treated as an implementation gap in the renderer
architecture rather than a product limitation.

Required implications:

- do not create a full-resolution `UIImage` for interactive preview;
- do not create full-resolution base, blurred, or mask textures for the whole
  image;
- do not render a full-resolution filtered image just to downsample it for a
  zoomed-out viewport;
- choose source LOD from the current zoom and destination viewport pixel size;
- keep low-zoom rendering close to display resolution;
- use original-resolution sampling only when the viewport is zoomed in enough to
  need it.

Current Sandbox baseline:

- the NASA entry uses `ImageProvider(fileURL:)`;
- the viewport source graph starts from `EditingStack.Loaded.editingSourceImage`
  so fit-to-screen rendering uses the existing 2560px editing source instead of
  immediately binding the 12000px progressive JPEG;
- this is a single low-zoom LOD baseline, not the final multi-LOD selection
  strategy needed for high-zoom inspection.

Review note:

Using `editingSourceImage` is provisional. It is acceptable for the current
NASA fit-to-screen benchmark because it establishes a low-zoom baseline without
forcing full-resolution source binding, but it should not be treated as the
final viewport source contract. Before moving this renderer out of the Sandbox,
we need to decide whether `editingSourceImage` is the right LOD input or
whether the viewport renderer should own a separate source pyramid / thumbnail
pipeline. The review should check image quality at high zoom, radius scaling,
color consistency, memory pressure, and whether this couples the interactive
renderer too tightly to `EditingStack`'s existing preview materialization.

## Non-goals For v1

- Shipping the shared preview inside PixelEditor or PhotosCrop.
- Full layer UI, reordering, opacity, blend modes, erase mode, or undo history.
- A complete export pipeline rewrite.
- Replacing all Brightroom filters with stateful reusable `CIFilter` objects.
  This can be optimized after the viewport preview contract is proven.

## Coordinate Systems

### Original Image Coordinates

The canonical storage coordinate space for masks is the orientation-up original
image pixel space.

- Origin: top-left after EXIF orientation has been applied.
- Unit: image pixels.
- Extent: oriented original image size.
- Crop never rewrites this data.

### Canvas Coordinates

The Sandbox canvas maps the oriented original image into a fixed canvas rect for
interaction and display.

- Strokes are collected in canvas coordinates while drawing.
- On commit, the stroke is converted to original image coordinates before being
  written to `EditingStack.Edit.LocalAdjustmentLayer.mask`.
- Rendering converts the visible viewport rect back to the matching original
  image region.

### Crop Coordinates

Crop is a render-time clipping and transform step.

- Local masks remain in original image coordinates.
- Cropped output clips the already composited image.
- Changing crop must not mutate local adjustment masks.

## Rendering Order

The full edited preview order is:

1. Decode source image.
2. Apply source orientation.
3. Apply global filters from `EditingStack.Edit`.
4. Apply local adjustment layers:
   - Render the adjusted image for the selected local effect.
   - Render or reuse the mask for the layer.
   - Composite adjusted over base using the mask.
5. Apply drawings, if enabled for the preview purpose.
6. Apply `RenderCrop` or crop clipping when producing final output.
7. Render the requested viewport into a reusable Metal texture.

The interactive viewport path must not route through `UIImage`, `UIImageView`,
or a fresh `CGImage` for each update. `CGImage` may still exist as an input
source or export target, but not as the interactive preview transport.

### Preview Purposes

`EditingStack` exposes separate image paths for different UI purposes. The UI
should not infer these policies by manually skipping filters.

Recommended shape:

```swift
extension EditingStack.Edit {
  enum PreviewPurpose {
    case editing
    case cropInteraction
  }

  func makePreviewImage(
    from sourceImage: CIImage,
    purpose: PreviewPurpose
  ) -> CIImage
}
```

The purposes should mean:

- `editing`: full interactive editing preview. This includes global filters,
  local adjustments, and any drawing layers that the edit screen needs to show.
- `cropInteraction`: crop composition preview. This should prioritize stable
  scroll/zoom/rotation interaction over exact final edited appearance.

The current crop interaction path starts conservative:

- apply source orientation and base normalization;
- do not apply expensive radius-based filters such as sharpen, unsharp mask, or
  Gaussian blur;
- do not apply local adjustment layers;
- do not require the viewport renderer or local adjustment source cache;
- allow lightweight color adjustments only if product validation shows they are
  needed for crop decisions.

This separation matches the observed Apple Photos behavior where Crop does not
appear to reflect at least some expensive adjustment state, such as maximum
sharpening. Crop should be treated as a geometry/composition tool, not as the
place where the full edit pipeline must be evaluated on every interaction.

Implementation status:

- `EditingStack.Edit.makePreviewImage(from:purpose:)` is the shared policy
  entrypoint.
- `EditingStack.Loaded.editingPreviewImage` uses `.editing`.
- `EditingStack.Loaded.cropInteractionPreviewImage` uses `.cropInteraction`.
- `EditingStack.Loaded.imageForCrop` is the current `CGImage` materialization
  used by Crop UI and follows the crop interaction policy.
- Crop interaction currently returns the normalized source image only; adding
  lightweight color-only adjustments should be a product decision, not an
  accidental side effect of reusing the editing preview.

### Local Adjustment Effect Policy

The local adjustment model should support more than blur. Diagnostic effects
should be added in performance groups:

- per-pixel effects: exposure, brightness, contrast, saturation;
- radius-based effects: Gaussian blur, sharpen, unsharp mask;
- future effects that need custom sampling or multiple passes.

Effects should declare how they respond to preview scale. Per-pixel effects do
not need scale conversion. Radius-based effects must convert from canonical
canvas/original pixel radius into the current preview pixel space when using a
downsampled viewport source.

The scaling hook should live with the effect model rather than only in the
Sandbox renderer, for example:

```swift
extension EditingStack.Edit.LocalAdjustmentEffect {
  func apply(
    to image: CIImage,
    previewScale: CGFloat
  ) -> CIImage
}
```

The exact API can change, but the invariant should remain: downsampled previews
must preserve the apparent radius of local effects relative to the displayed
image.

## Core Image Graph Policy

`CIImage` should be treated as an immutable render recipe, not as an already
materialized bitmap. Constructing a new `CIImage` graph is usually cheaper than
rendering it, but in this canvas the same expensive subgraphs are consumed by
many visible tiles. The graph therefore needs explicit reuse boundaries.

### Required Boundaries

- Build a render graph once per edit generation, not once per tile.
- Keep one long-lived Metal-backed `CIContext` for the canvas renderer.
- Render each tile by cropping and transforming the graph into that tile's
  destination texture.
- Reuse Metal destination textures and IOSurfaces while their pixel size is
  unchanged.
- Treat the original image source as a lazy source. `CGImageSource`/file-backed
  input is preferred for large images; `UIImage` is only acceptable for small
  demo images or already-decoded app assets.

### Large Source Strategy

The renderer needs an explicit source abstraction that can answer:

- image metadata and orientation without decoding the full image;
- low-resolution preview images for zoomed-out display;
- tile-sized or LOD-sized render input for the current destination pixel size;
- original-resolution input only when the visible tile needs it.

For ordinary JPEG, true arbitrary region decode may not be available in the way
tiled image formats provide it. The fallback strategy is to build or cache a
bounded image pyramid:

- small overview LODs via `CGImageSourceCreateThumbnailAtIndex`;
- display tile render from the closest sufficient LOD;
- high-zoom tiles from original-resolution sampling;
- optional background prewarming for nearby tiles and LODs.

The key invariant is that the interactive path never requires several
full-resolution 12000 x 12000 intermediates to exist at the same time.

The expected shape is closer to Photos than to a document viewer with one giant
backing image:

- persistent source object with metadata-first loading;
- multi-resolution display pyramid or equivalent Core Image / ImageIO cache;
- tile render requests driven by viewport and zoom;
- bounded concurrent render queue;
- cancellation and generation checks for superseded edits;
- immediate low-resolution feedback followed by sharper replacement when needed.

### Intermediate Insertion

Use Core Image intermediates as explicit graph checkpoints:

- Use `insertingTiledIntermediate()` for the global-filtered base image when the
  result is sampled by many independent display tiles.
- Use `insertingIntermediate(cache: true)` only for subgraphs that are expensive
  and stable for the current edit generation. Example: a blurred image reused by
  several local-adjustment tiles.
- Avoid forcing a full-image blurred intermediate while the blur radius is zero
  or no visible tile intersects a local mask.
- Do not use intermediates to hide excessive tile concurrency. Scheduling must
  still be bounded.

Apple's contract matters here: `insertingIntermediate()` adds a cacheable
intermediate, but it follows the context's `cacheIntermediates` behavior.
`insertingIntermediate(cache: true)` can force cacheability even when the context
would otherwise not cache intermediates. `insertingTiledIntermediate()` is the
preferred candidate for a zoomable canvas because the consumer naturally asks for
rectangular tile regions.

### Filter Instance Reuse

Reusing `CIFilter` instances can reduce object churn, but it is a secondary
optimization and must not leak mutable filter state across concurrent renders.

### Core Image Composite Experiment

The Sandbox uses Core Image for local-adjustment composition. It rasterizes the
brush mask into a Metal texture, wraps that mask as a `CIImage`, builds the
base/effect/mask blend with `CIBlendWithAlphaMask`, then renders that graph
directly to the drawable.

The previous Metal final-blend shader was removed after simulator and device
checks showed no meaningful advantage over Core Image for this diagnostic path.
Metal still owns brush and mask rasterization; the removed code is only the
custom local-adjustment final composite shader and its renderer toggle.

Validation should use `CI_PRINT_TREE`:

- graph type `2` to inspect Core Image's optimized graph;
- graph type `4` to inspect GPU program concatenation and intermediate buffers;
- compare Exposure and Blur separately, because per-pixel effects can
  concatenate more aggressively than radius-based effects;
- verify whether mask bounds and visible viewport bounds reduce the ROI before
  expensive filters run.

Initial observation: launching `SwiftUIDemo` with `CI_PRINT_TREE=4` and drawing
an Exposure stroke in the NASA sandbox prints a `MetalBrushSandboxCanvas`
program graph whose final render contains `_blendWithAlphaMask` and the exposure
color-matrix work in the Core Image program path. That is evidence that the CI
diagnostic mode is exercising the intended graph. It is not yet proof that this
is always the fastest possible path, because the remaining ROI and intermediate
behavior still needs to be compared across Exposure and Blur.

The CI path also owns the first explicit per-layer viewport caches:

- base layer cache: viewport source plus global filters rendered into a
  viewport-sized Metal texture;
- local layer cache: the selected local adjustment effect rendered from the
  cached base layer into another viewport-sized Metal texture.

These caches are invalidated by source/filter changes, local effect changes,
viewport changes, and drawable size changes. Brush, mask, and committed-stroke
changes do not invalidate them, so local mask editing can reuse the base and
adjusted layers while only re-rasterizing the mask and running the final
`CIBlendWithAlphaMask` composite.

The v1 contract is:

- The render graph owns any reusable filter instances.
- A filter instance is used on one serial render queue or protected by a clear
  ownership boundary.
- The public `EditingStack.Edit` model remains value-based and non-destructive.
- The viewport renderer receives immutable `CIImage` graph outputs for the
  current edit generation.

## Viewport Cached Renderer Requirements

### Source Cache Sizing

The viewport source cache is a Metal texture sized to the current drawable, not
to the original image:

```text
pixelWidth  = viewportDrawable.width
pixelHeight = viewportDrawable.height
```

When zoomed out, the cache covers a large logical image region but is backed
only by display-resolution pixels. When zoomed in, the visible source rect
narrows, so the Core Image input area shrinks even though the drawable size is
roughly constant.

### Cache Invalidation

- Pan, zoom, layout changes, and drawable-size changes invalidate the viewport
  source texture.
- Global filter changes reuse the viewport source texture and rebuild the
  filtered/effect/composite output from the cached source.
- Local effect value changes reuse the viewport source texture.
- Radius-based effects convert their canvas-space radius into viewport pixel
  space before applying the Core Image filter.

### Memory

- Viewport scratch textures are reused when the drawable pixel size is stable.
- The canvas must not retain textures for historical zoom levels after they are
  no longer visible.
- Exposure and other global slider updates should rewrite existing destination
  buffers rather than allocating a fresh display surface per tick.

## Brush Preview Requirements

The active stroke is rendered by the same viewport `MTKView` as the committed
preview.

- Target refresh rate: up to 120 Hz when the device supports it.
- Active stamps and committed strokes use the same mask brush shader.
- The mask texture size follows the viewport drawable, not the full original
  image.
- When a stroke is committed, `EditingStack.localAdjustments` becomes the source
  of truth and the viewport mask is rebuilt from committed strokes.

## EditingStack Model

`EditingStack.Edit` owns local adjustments:

```swift
struct LocalAdjustmentLayer {
  var id: UUID
  var isEnabled: Bool
  var effect: LocalAdjustmentEffect
  var mask: LocalAdjustmentMask
}

enum LocalAdjustmentEffect {
  case gaussianBlur(radius: Double)
  case exposure(value: Double)
}
```

The model contract:

- Layers are part of the edit model, not view-local state.
- Masks are stored in orientation-up original image coordinates.
- The Sandbox may keep a temporary active stroke outside the model until commit.
- The viewport renderer synchronizes committed strokes from
  `EditingStack.localAdjustments`.

## Debugging And Observability

The renderer should expose logs that answer:

- Which visible rect is being rendered?
- What drawable pixel size and contents scale are used?
- Which path was used: base-only or local-adjustment composite?
- Which edit generation produced the result?
- Was the viewport source cache reused or rebuilt?
- Was a cached intermediate expected to be reused?

Logs should be compact enough to leave enabled in Sandbox development, but
should be gated behind an `OSLog` category or debug flag before production use.

## Current Known Issues

These are the current gaps between the target design and the observed Sandbox
behavior. They should be treated as active implementation and validation tasks,
not as accepted trade-offs.

### Interactive Filter Latency

Exposure and other global filter sliders can still feel behind the finger on
device. The desired behavior is that parameter changes rebuild a lightweight
render graph from the cached viewport source and rewrite existing viewport
textures without allocating new display surfaces. The current implementation has
texture reuse, but it still needs profiling to prove:

- the profiling path is not dominated by SwiftUI view invalidation from
  high-frequency slider state;
- viewport source cache misses happen only on geometry or drawable-size changes;
- Core Image is not re-binding the original large source on every slider tick;
- `insertingIntermediate(cache: true)` improves real device latency without
  causing memory spikes;
- `CIFilter` instance reuse would reduce meaningful object churn rather than
  adding unsafe mutable shared state.

### Core Image And IOSurface Warnings

Device logs have shown repeated compressed-photo IOSurface creation failures and
a Core Image working-format warning. The intended canvas path should not create a
new `CGImage` or `UIImage` for interactive viewport updates, but the source image
decode and Core Image input path still need validation on device.

Required checks:

- identify whether `IOSurfaceName = CMPhoto` logs still originate from the input
  image source after the decoded `CGImage` path;
- ensure the canvas `CIContext` working format is one Core Image accepts for
  Metal rendering;
- confirm that these logs do not repeat on every slider tick or viewport render.

### Viewport Cached Source Preview

The Sandbox no longer keeps the committed `CALayer` tile grid as an active
interaction path. The previous tile modes answered the main diagnostic question:
the expensive part was tile scheduling / IOSurface-CALayer transport / repeated
source binding, not Core Image filters in isolation. The current Sandbox
therefore uses one viewport-sized `MTKView` path for the interactive preview.

The old diagnostic matrix (`Full`, `Filtered`, `Viewport`, `VP Full`) should be
treated as historical evidence, not as modes that must stay wired in the demo.
The next product architecture may still add still-state tiles or a high-quality
cache after interaction settles, but the interactive contract is now viewport
first.

`VP Cached` materializes the current visible source rect into a viewport-sized
Metal texture before global filters, local adjustment effects, mask
rasterization, and composite are evaluated.

Expected behavior:

- pan/zoom changes invalidate the viewport source texture;
- filter and blur slider changes reuse the same viewport-sized source texture;
- global filters run against the small `CIImage(mtlTexture:)` source rather
  than the original large image graph;
- local adjustment effects and mask composite stay in viewport-sized work;
- radius-based effects scale their radius into viewport pixel space;
- local Exposure and Blur both compose through `CIBlendWithAlphaMask` rather
  than a custom final-blend Metal shader.

Drawing behavior:

- active strokes are rasterized into the same viewport mask texture as
  committed strokes, so drawing is visible before the stroke is committed;
- viewport active-stroke redraws are coalesced with a display link while the
  stroke is in progress, with immediate redraws preserved at begin/end;
- committed strokes are synchronized from `EditingStack.localAdjustments`;
- the Sandbox currently mutates the existing Sandbox layer when switching local
  effect kind, so the same mask can be compared as Blur or Exposure;
- the metrics row reports committed plus active stamp counts, stroke count, and
  a draw-call FPS sampled from actual `MTKView.draw(in:)` calls.

The SwiftUI demo includes a `Metal Brush Sandbox NASA` entry that loads the
bundled `nasa.jpg` with `ImageProvider(fileURL:)`. This is the preferred
benchmark entry because it avoids creating a full-resolution `UIImage` before
the viewport cached source renderer runs.

### Viewport Source Cache Validation

The current renderer needs instrumentation that logs, per viewport render:

- visible content rect in canvas points;
- visible canvas frame in viewport coordinates;
- zoom scale and screen scale;
- drawable pixel size;
- cache hit or miss for the viewport source texture;
- local effect kind and whether the local effect is active;
- render path, either base-only or local-adjustment composite.

This should make it clear when fit-to-screen uses display-resolution
downsampling and when zoom-in narrows the Core Image workload to a smaller
source rect.

### Viewport Interaction Consistency

Rapid zooming, rubber-banding, and drawing still need stress validation in the
viewport path. The important invariant is that the `UIScrollView` remains the
source of geometry truth; the `MTKView` should not apply an independent scale or
anchor correction that can pull the image toward the top-left.

This area still needs validation for:

- pan and pinch while the viewport source cache is being refreshed;
- drawing immediately after zoom or pan;
- active stroke display before commit;
- committed mask position after zooming in and back out;
- preserving the native zoom bounce visual while avoiding unnecessary cache
  rebuilds during rubber-banding where possible.

This mode exists to test whether interactive cost can be bounded primarily by
the drawable size instead of the original image size. It is still possible that
the initial source materialization remains expensive for huge `CGImage` backed
inputs because Core Image may still need to bind or decode the large source.
The important trace question is whether source binding disappears from slider
updates after the viewport source texture is cached.

The NASA baseline currently avoids the full-resolution source at fit by using
the editing-source LOD. Future work should replace that single LOD with
zoom-aware source selection so high zoom can opt back into higher-resolution
image data only when the viewport actually needs it. This also needs a focused
design review: `editingSourceImage` is a useful temporary LOD, but it may be the
wrong long-term abstraction if the viewport renderer needs independent decode,
cache, and quality policy.

If this path remains fast across several local adjustment effects, the next
architecture step should be to promote the viewport cached source renderer out
of the Sandbox and make the tile renderer optional or secondary.

### Tiled Renderer Status

The committed tile renderer has been removed from the active Sandbox code path.
It remains a historical diagnostic comparison and may later be reintroduced for
still-state caching, high-quality background refresh, or very specific
large-canvas workflows. It should not be treated as the default interactive
display architecture until there is stronger evidence that it can avoid repeated
source binding, per-tile fixed costs, and IOSurface/CALayer transport overhead
during high-frequency edits.

The current product direction is:

- interactive editing preview: viewport cached source renderer;
- local adjustment brush preview: active and committed masks in the viewport
  renderer;
- crop interaction preview: separate crop-purpose image path, likely not the
  full edited preview;
- tile renderer: optional later optimization, not required for v1 interaction.

### Active And Committed Visual Parity

The active stroke preview and committed viewport output must match in position,
alpha, and color. Previously observed symptoms in the old split path included a
slightly different live opacity or color and a flash when a stroke moved from
live rendering to committed tiles.

Open validation work:

- compare live mask shader output and committed mask shader output using the
  same brush parameters;
- verify that premultiplied alpha and color-space choices are identical between
  active and committed viewport composition;
- verify that committing a stroke does not flash or visually move the mask.

### Mask Rendering Path Split

The Sandbox viewport renderer can rasterize brush masks with Metal, but the
engine-level `EditingStack.Edit.LocalAdjustmentMask.makeCIImage(size:)` path
still uses a UIKit bitmap renderer and then wraps a `CGImage` as a `CIImage`.
That may be acceptable for export or compatibility, but it is not the desired
interactive transport for the shared viewport preview.

Before PixelEditor or PhotosCrop adopt this canvas, the mask path should be
split explicitly:

- interactive preview: Metal mask texture or cached CI/Metal-backed mask;
- engine/export compatibility: existing `CGImage` mask path until replaced;
- tests: prove both paths produce equivalent mask coverage.

### Crop Integration

The v1 Sandbox primarily validates un-cropped canvas behavior. The specification
requires masks to stay in original image coordinates while crop is applied only
at render time. This still needs direct tests that change crop after local masks
exist and verify that cropped output clips the adjustment without moving the
mask.

### Test Coverage

The current Maestro flow is useful as a smoke test, but it is not enough to
prove the viewport cached preview. Meaningful automation should cover:

- view mode versus draw mode;
- double-tap zoom and pan in view mode;
- drawing after zoom and pan;
- exposure changes while zoomed;
- blur radius changes with and without committed masks;
- switching the local adjustment effect between Blur and Exposure;
- reset after local adjustments;
- assertions based on logs or screenshots that viewport cache hits and misses
  happened at the expected pixel sizes.
- the NASA Sandbox entry maintains stable draw-call FPS while panning, zooming,
  and adjusting Exposure with no committed local mask.
- Core Image composite produces stable mask placement and color for Blur and
  Exposure at fit and after zooming.

## Acceptance Criteria

- Global filter-only updates apply in near real time without unbounded allocation.
- The 12000 x 12000 NASA benchmark image can zoom, pan, and update Exposure
  without routinely allocating full-resolution intermediates.
- `Blur = 0` produces the same visual output as no local adjustment.
- With `Blur > 0`, only the painted region changes.
- Active stroke position matches committed mask position at 1x and high zoom.
- Zooming and panning do not move existing local masks.
- Repeated zooming does not grow memory indefinitely.
- Viewport cache rebuilds remain bounded during rapid zoom and slider changes.
- No interactive path repeatedly creates `CGImage` or `UIImage` outputs.
- The implementation can explain, through logs, why a given viewport source
  cache was rebuilt.

## Open Questions

- Whether still-state tiles or a higher-quality cache should exist after
  interaction settles, or whether the viewport renderer is enough for v1.
- Whether `EditingStack.Loaded.editingSourceImage` should remain the low-zoom
  viewport source, or whether viewport rendering needs its own explicit LOD
  provider independent of the existing editing preview image.
- Whether radius-based local adjustment effects should share a generic
  `RadiusCalculator`-style scaling policy with global filters.
- Whether global filters should move to reusable `CIFilter` instances inside a
  canvas render graph after profiling confirms object churn is meaningful.
- How to share this canvas with PixelEditor and PhotosCrop without coupling those
  products to Sandbox-only debug controls.
