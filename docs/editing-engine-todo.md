# Editing Engine — Open TODO

Near-term, actionable follow-ups for the parametric editing/rendering work. The
broader direction lives in [`vision-of-editing.md`](./vision-of-editing.md); this
file tracks concrete engineering items that are not yet done.

Status context (as of Brightroom 6):

- `EditingStack` holds no edit. ImageEditor and `ImageEditorCanvas` edit an
  `ImageEditorFeature` (a statically composed `Feature`) owned by
  `PhotosCropEditingModel` or the host; crop is a parametric `CropFeature`.
  BrightroomUI edits crop through `CropEditingState` / `CropRotation`.
- Brush-mask rasterization shares ONE falloff (`BrushStampFalloff.metalh`)
  across the export/preview CIKernel (`ParametricKernels.metal` `brushStamp`)
  and the live Metal render shader (`BrushMaskRenderShader.metal`).
- The live canvas renders committed + active strokes in one real-time Metal pass
  (no committed-mask cache). Export/preview stay on Core Image (auto-tiling).
- The local-adjustment **preview is evaluated at the downsampled editing-source
  resolution and upscaled**, not at `canvasSize` (the full oriented image size).
  Blurring the full-canvas image OOM-crashed huge sources (the 12000×12000 "Nasa"
  image); the blur radius is a fraction of the image extent, so evaluating at the
  ~2560 source and upscaling reproduces the same fractional blur the
  full-resolution export produces. See `EditingCanvasRenderImageFactory`
  `.localAdjustment` in both `makeRenderImages` and `makeCropOutputRenderImages`.
  A small preview↔export resampling discrepancy is inherent and accepted (any
  editor downsamples its preview).
- `BrightRoomImageRenderer` has a SINGLE rendering path AND a single public
  entry point: `func render(options:) async throws -> Rendered`. The render
  compiles the edit (effects, local adjustments, crop-as-domain-feature) to one
  `CIImage` recipe via `ParametricImageRenderer` and evaluates it on the
  renderer's private serial queue (off the calling actor). The old CoreGraphics
  fast path (`renderOnlyCropping` / `axisAlignedCropOnlyFeature` /
  `pixelCropRect` / `Rendered.Engine`), the completion-handler `render`, and the
  separate `renderToFile` are all deleted.
- Output is chosen via `Options.output`, and `Rendered` HIDES the disk/memory
  backing (`cgImage` / `uiImage` are `get throws`; `fileURL` is non-nil only for
  file output):
  - `.memory` → in-memory `CGImage` via `CIContext.createCGImage(from: fullExtent)`,
    which allocates the whole output bitmap (≈ W·H·4 bytes; ~576MB at 12000²) —
    the export memory spike.
  - `.file(url:fileType:)` → bounded-memory disk write via
    `CIImageStreamingFileWriter`: render the recipe **strip-by-strip** with
    `CIContext.render(_:toBitmap:bounds:)` into a **mmap'd temp file** (bytes on
    disk, not RAM), wrap that buffer in a `CGImage` via a lazy
    `CGDataProviderCreateDirect`, and encode with `CGImageDestination`, which
    demand-pages through the provider. Peak RAM ≈ one strip + CI scratch +
    encoder working set; the full bitmap stays on disk. This REPLACED
    `CIContext.write{JPEG,HEIF}Representation`, which renders the whole bitmap
    into RAM first (the observed ~576MB spike). Output JPEG/HEIC/PNG. To preview
    a large file result WITHOUT a full-resolution decode spike, use
    `Rendered.thumbnail(maxPixelSize:)` (Image I/O downsample-decode), not
    `Rendered.cgImage` (which decodes full).
  `Resolution.resize` is a CI-side Lanczos scale on the recipe for both outputs.
  - OPEN: the encode step's demand-paging is not Apple-documented — verify the
    peak-memory win on-device with Instruments (Allocations / VM Tracker); tune
    `CIImageStreamingFileWriter.defaultStripHeight`. Confirm custom CIKernels
    (`brushStamp`) tile under `render(bounds:)` (no "ROI function did not allow
    tiling"). Guards: `DiskExportTests` (full-res, masked, resize, orientation,
    channel-order).
- Pixel-level guards: `BrushMaskRasterizerParityTests` (live Metal == export
  CIKernel), `BrushStampFalloffTests`, `LargeMaskedExportTests`,
  `MaskedPreviewExportScaleConsistencyTests` (source-res blur preview ≈ full-res
  export), `CropSurfaceBlurRenderPathTests` (prepared-path routing),
  `DiskExportTests` (render with `Output.file`: full-res, masked, resize), plus the existing
  crop/orientation/parity suites.

---

## TODO

### 1. Optimize the export brush-mask rasterizer — `MaskTreeRenderer.render(_:BrushMask)`

The Core Image path accumulates one full-extent CIImage per stamp via `componentMax`
(an O(stamps)-deep graph, each stamp evaluated over the whole extent). Slow and
memory-heavy for many-stamp masks at export. Keep it on Core Image (it auto-tiles
images too large for a single GPU texture). Options, ranked, all parity-safe unless
noted:

- **(a) Bounding-box crop each stamp** to `center ± radius` so the `brushStamp`
  kernel only evaluates the disk (O(extent) → O(stamp area) per stamp). Pixel-identical.
- **(b) Decimate near-duplicate stamps at commit** (e.g. drop stamps within
  `radius/4` of the previous). Reduces N for BOTH export and live; do it before
  either path consumes the stamps so parity is preserved.
- **(c) Tree-reduce the `componentMax` chain** (pairwise → graph depth O(log N))
  to ease Core Image concatenation / intermediate-buffer pressure.
- **(d) [bigger] Per-stroke distance-to-polyline kernel** (N stamps → S strokes).
  Biggest win for huge masks, but it changes the rasterization geometry, so the
  live Metal shader must be made polyline-based too, or live/export diverge.

Files: `Sources/BrightroomParametric/MaskTreeRenderer.swift`,
`Sources/BrightroomParametric/ParametricKernelRegistry.swift`.
Guards: `BrushMaskRasterizerParityTests`, `EditingPreviewExportParityTests`,
`LocalAdjustmentRenderingTests`.

### 2. Unify the live Metal rasterizer (MTKView ↔ `BrushMaskMetalRasterizer`)

`BrushMaskMetalRasterizer` (added for the parity test) duplicates the inline stamp
encode + pipeline setup in `EditingCanvasMTKView.encodeStrokeMaskForViewport` /
`makeBrushMaskPipeline`. The falloff is shared, but the Metal encode/pipeline is
not. Refactor the MTKView to use `BrushMaskMetalRasterizer` so there is literally
one live Metal rasterizer.

Files: `Sources/BrightroomUI/Canvas/EditingCanvasMTKView.swift`,
`.../BrushMaskMetalRasterizer.swift`.

### 3. Done: Store masks y-up in the document — "E5"

`ImageEditorFeature` stores brush stamps in Core Image's y-up working space, and
the y-down bridge (`EditingDocumentBridge`) is deleted, so the document is
directly renderable. The canvas converts gestures to y-up when it commits a
stroke.

Guards: `LocalAdjustmentMaskOrientationTests`, `EditingPreviewExportParityTests`,
`PreviewExportVisualEvidenceTests`.

### 4. Reconcile / retire the committed-mask cache WIP

The all-real-time-no-cache change removed the committed-mask cache machinery from
`EditingCanvasMTKView`. Any remaining pieces of the earlier committed-mask-cache
effort (e.g. the untracked `CommittedMaskParametricParityTests.swift`, and stale
comments referencing a committed-mask bake) should be reconciled with the live
real-time path or removed.

### 5. Manual verification pass (ImageEditor)

Live paint position/orientation and zoom memory were confirmed visually. Remaining:
a full ImageEditor pass on device/sim — pan/zoom, 90° rotate, straighten dial,
aspect-ratio lock, reset — and confirm the exported result matches the on-screen
preview. **Re-test drawing a mask on the 12000×12000 "Nasa" image** — the OOM
that motivated the source-resolution-blur change cannot be unit-tested (it is a
device memory-watermark crash), so it needs a manual confirmation.

### 5a. Crop Done / tool switch before a gesture settles (from #330)

ImageEditor's Done and a switch from Crop to a tool commit the proposed crop,
which is the last *recorded* interaction state. Pressing Done or switching
before a scroll/pinch settles can omit the final unrecorded movement; there is
no synchronous gesture flush. Quarter-turn crops (straighten → crop → quarter
turn, `CropFeature.OutputGeometry`) are covered by unit and UI tests on the
Simulator but have not been verified on a physical device.

Files: `Sources/BrightroomUI/Canvas/EditingCanvasView.swift`
(`applyDocumentChanges()`, `record()`).

### 6. (If global spatial effects land) downsample the global-effect preview too

The source-resolution-blur fix covers the **local-adjustment** preview path
(`.localAdjustment`). The `.preview` / `.renderedEditPreview` paths still apply
the global effects (`ImageEditorFeature.Effects`) to the full-canvas image. That is safe today because
every global effect ImageEditor exposes is pointwise (exposure/contrast/etc.) —
Core Image evaluates those lazily at the output/viewport resolution, so no
full-canvas buffer is materialized. If a global **spatial** effect (blur,
sharpen, displacement) is ever added to the global effects, that path would
materialize a full-canvas intermediate and could OOM on huge sources; apply the
same source-resolution-then-upscale treatment there.

Files: `Sources/BrightroomUI/Canvas/EditingCanvasRenderImageFactory.swift`.

### 7. Texture bit-depth / memory for the GPU-resident source + content bake

The crop-rotation perf work in `EditingCanvasView` added persistent GPU
textures. Two memory reductions are **done**; one open question remains.

Done:
- **Adaptive source depth.** `EditingSourcePreparation.makeGPUResidentSource`
  picks the texture format from `cgImage.bitsPerComponent`: `rgba8Unorm` for an
  8-bit source (the common case — lossless, half the memory), `rgba16Float` for
  >8-bit / HDR (preserves precision + extended range). Guard:
  `EditingSourceTextureTests` sweeps both depths × 8 orientations.
- **Bake only the expensive layer.** The content bake now bakes ONLY `adjusted`
  (the blur), not `base`. `base` is the global effects on the GPU-resident source
  — pointwise, so re-evaluating it per frame is cheap and needs no held texture.
  When there is no local effect, nothing is baked. (See `preparedAdjustedLayer`.)

Net (8-bit source): plain crop/rotate now holds just the source texture (~26MB,
~back to the pre-change CGImage footprint); a blur-mask gesture adds one ~52MB
`adjusted` bake. Down from ~104MB / ~156MB.

Open:
- The `adjusted` bake is still `rgba16Float` (`colorTextureFormat`). It can't
  simply drop to 8-bit: it holds the effects+blur result in the
  **extended-linear-Display-P3** intermediate space, where 8-bit *linear* bands
  in shadows and can't carry out-of-[0,1] (exposure overshoot / wide gamut). Any
  reduction here must be gated on the wide-gamut/EDR color contract, not the
  source's nominal depth. Lower-risk levers if the bake memory still matters:
  cap the bake nearer the drawable resolution instead of the 2560 source cap, or
  a 10-bit option for confirmed-SDR-in-range content. Measure on-device first.
- Confirm on device that keeping `base` as a live (un-baked) graph did not
  re-introduce per-frame cost (it shouldn't — pointwise on a GPU texture).

Files: `Sources/BrightroomEngine/Engine/EditingSourcePreparation.swift`,
`Sources/BrightroomUI/Canvas/EditingCanvasContentBake.swift`,
`Sources/BrightroomUI/Canvas/EditingCanvasMTKView.swift`
(`preparedAdjustedLayer`),
`Sources/BrightroomUI/Canvas/EditingCanvasGeometry.swift`
(`colorTextureFormat`).
