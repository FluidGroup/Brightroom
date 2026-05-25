# muukii/state-graph Merge TODO

This file tracks the remaining work needed before the `muukii/state-graph`
branch is ready to merge.

## Merge Blockers

- [x] Fix PhotosCrop real-device pinch regression.
  - Symptom: On a physical device, open `PhotosCrop` > `Horizontal`, start from
    Reset, select `16:9`, switch to `Vertical`, then pinch zoom. The guide
    stretches away from the vertical 16:9 ratio. Simulator runs have not
    reproduced it.
  - Current diagnosis: The log in `/Users/hiroshi.kimura/Downloads/log` shows
    the crop is valid immediately after selecting vertical 16:9
    (`cropAspect: 0.5625`). During pinch, `scrollViewWillBeginZooming` starts a
    `.zoom` adjustment, but the device also emits `scrollViewWillBeginDragging`,
    which overwrites the adjustment kind to `.drag`. The delayed settle path then
    records a guide-derived crop through the drag-only normalization path, and
    the crop aspect becomes `0.4902`.
  - Simulator comparison: `/Users/hiroshi.kimura/Downloads/simulator.log` follows
    the same aspect-ratio setup, but no `drag-begin` appears during pinch. The
    adjustment remains `.zoom` through settle, records with `source: .zoom`, and
    preserves `resolvedAspect: 0.5625`.
  - Suspected introduction point: `c2da242 Move crop loading boundary into
    SwiftUICropView`, where `scrollViewAdjustmentKind`,
    `scrollViewAdjustmentBaselineCrop`, `scrollViewSettleDebounce`, and
    `normalizedCropExtentForScrollViewRecording` were added.
  - Fix:
    - Ensure `record()` re-applies `preferredAspectRatio` when a
      locked aspect ratio is active. This should keep `resolvedAspect` at
      `0.5625` even if the physical device still records through
      `source: .drag`. The DEBUG log now prints both `normalizedAspect`
      before the guard and `resolvedAspect` after the guard.
    - Do not let `scrollViewWillBeginDragging` overwrite an active
      zoom adjustment. Drag endings are now also ignored unless the active
      adjustment is `.drag`, so a device-only drag callback during pinch should
      no longer settle the zoom as a drag.
  - Verified on device: The reported guide-stretching behavior and the first
    zoom auto-correction are no longer reproduced after the zoom interaction
    guard was added. The post-cleanup implementation was also retested on device
    and looked correct.
  - Acceptance:
    - Physical device no longer stretches the guide for the reported sequence.
    - Simulator behavior remains unchanged.
    - The existing PhotosCrop aspect-ratio selection and guide-drag workflows
      still work.

- [x] Decide whether the temporary CropView diagnostics should stay.
  - Decision: Keep a compact DEBUG-only trace for scroll adjustment transitions
    and crop recording aspects, but remove the high-volume crop layout dump.
  - Rationale: The remaining logs preserve the evidence needed for this device
    class of issue without making normal crop layout noisy.

- [ ] Audit the current dirty worktree and split required work from experiments.
  - Pay special attention to the untracked Metal brush sandbox files and any
    debug-only changes that were introduced while investigating the regression.
  - Keep `implementation-notes.html` and this TODO file only if they are intended
    merge artifacts.

## API And Product Cleanup

- [ ] Recheck public API changes caused by removing ClassicImage editor
  surfaces.
  - Confirm package products, deleted files, migration notes, and demo entry
    points are all consistent.

- [ ] Recheck PhotosCrop UIKit-to-SwiftUI hosting behavior.
  - `PhotosCropViewController` now hosts `SwiftUIPhotosCropView`.
  - Ensure completion, cancellation, reset, rotation, fixed/selectable aspect
    ratio options, and localized strings preserve the expected public behavior.

- [ ] Recheck PixelEditor SwiftUI migration behavior.
  - Confirm masking, drawing, filter, render, and preview paths still update the
    editing stack correctly.

- [ ] Rework the adjustment-layer model before stabilizing
  `SwiftUIEditingCanvasView` as a primitive component.
  - Current issue: `EditingStack.Edit.LocalAdjustmentEffect` is a concrete enum
    with cases such as blur and exposure. It is useful for the experiment, but
    it is not yet an abstract or extensible adjustment-layer contract.
  - Current issue: Important viewport paths still behave like a single active
    local-adjustment-layer renderer. Multiple ordered layers are not modeled as
    a first-class viewport graph yet.
  - Decide the API for layer creation, selection, deletion, reordering, effect
    replacement, and mask editing so product UIs can compose their own editing
    screens without depending on PixelEditor-specific behavior.
  - Define the renderer/compositor contract for multiple ordered local
    adjustment layers, including the cache boundary for base, per-layer effect,
    masks, and final composite.

- [ ] Decide whether `editingPreviewImage` should remain part of the production
  preview architecture.
  - The new viewport canvas path intentionally avoids depending on it.
  - Recheck whether any remaining production surfaces still require it, or
    whether it should become a compatibility-only/materialized-preview path.

- [ ] Strengthen PixelEditor and crop automation around repeated edit cycles.
  - Cover filter selection, crop, mask drawing, base adjustment, returning to
    crop, and applying another mask.
  - Assert that edits are reflected in the final rendered output, not only that
    the screens open and accept gestures.

- [ ] Revisit EditingCanvas zoom-bounce rendering architecture.
  - Problem: The current editing canvas keeps the visible `MTKView` pinned to
    the viewport while a separate dummy/content view participates in
    `UIScrollView` zooming. This keeps Metal rendering cost viewport-sized, but
    the Metal content does not naturally participate in `UIScrollView`
    rubber-band zoom animations.
  - Current symptom: When the user pinches below the minimum zoom scale and
    releases, `UIScrollView`'s zoom bouncing/return animation is not visible in
    the Metal-rendered image. The content can snap back to the final size even
    though the scroll view is still rubber-banding.
  - Acceptance: Pinch-to-shrink past the minimum zoom should visibly squash and
    rebound like a normal `UIScrollView` zooming content view, without forcing
    the Metal drawable to become full-image sized.
  - Direction to explore: Let `UIScrollView` zoom a real canvas-coordinate
    content view, while the Metal surface behaves as a viewport patch that draws
    only the visible canvas rect plus overscan. Do not make the `MTKView`
    full-canvas sized.
  - Option A: Put `MTKView` inside the zoomed content and allow UIKit to scale it
    during gestures. This should restore native bounce, but a fixed drawable can
    look soft while zooming.
  - Option B: Put a patch container inside the zoomed content and apply inverse
    scale to `MTKView`. This can keep the Metal surface visually stable, but may
    cancel the rubber-band enlargement that should be visible.
  - Option C: Use Option A while gesture/rubber-band is active, then settle back
    into a stabilized viewport patch after interaction ends. This may offer the
    best UX, but needs careful coordinate and redraw policy design.
  - Constraints:
    - Keep Metal cost tied to viewport pixels plus overscan.
    - Avoid resizing the drawable on every zoom tick.
    - Keep saved strokes in image-space/canvas-space, independent of patch view
      placement.

## Validation Checklist

- [ ] Run whitespace/syntax hygiene.
  - `git diff --check`

- [ ] Build the SwiftUI demo app with the project workflow.
  - Prefer the configured Xcode MCP workflow when available.
  - Fallback command:
    `cd Dev && xcodebuild -scheme SwiftUIDemo -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build`

- [ ] Run focused engine tests for renderer/crop changes.
  - Include `RenderCropTests`, `RenderCropRendererTests`, and existing renderer
    tests if available in the test target.

- [ ] Run app-level automation for the edited surfaces.
  - `.maestro/photos-crop.yaml`
  - `.maestro/pixel-editor.yaml`
  - Any additional sandbox flow that remains part of the branch.

- [ ] Perform at least one physical-device PhotosCrop smoke test.
  - Include the reported Horizontal > 16:9 > Vertical > pinch sequence.
  - Include one guide-drag sequence after aspect-ratio lock.

## Merge Hygiene

- [ ] Ensure the branch is up to date with `main` and resolve conflicts
  intentionally.

- [ ] Review commit boundaries.
  - Keep renderer boundary work, SwiftUI migration work, demo/automation work,
    and regression fixes understandable as separate commits when possible.

- [ ] Review docs and migration notes.
  - Confirm `docs/MIGRATION_VERGE_TO_STATEGRAPH.md` still matches the final code.
  - Confirm README/package references do not point to deleted public surfaces.

- [ ] Confirm no local-only artifacts are accidentally staged.
  - Check untracked files.
  - Check generated project or lockfile changes are intentional.
