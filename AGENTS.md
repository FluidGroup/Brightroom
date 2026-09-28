# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Brightroom is a composable image editor library for iOS, powered by Metal for high-performance image processing. It provides both low-level image editing capabilities and high-level UI components.

## Build Commands

### Building via Xcode Project (Recommended)
```bash
# Build BrightroomUI (includes BrightroomEngine and BrightroomParametric)
cd Dev && xcodebuild -scheme BrightroomUI -destination 'generic/platform=iOS Simulator' -skipMacroValidation -skipPackagePluginValidation build

# Build SwiftUI Demo app
cd Dev && xcodebuild -scheme SwiftUIDemo -destination 'generic/platform=iOS Simulator' -skipMacroValidation -skipPackagePluginValidation build
```

Note: `swift build` does not work due to macOS version constraints. Always use `xcodebuild` with the Dev/Brightroom.xcodeproj.

### Running Demo Apps
```bash
# Open the development workspace
open Dev/Brightroom.xcodeproj
```

## Architecture

### Core Modules

1. **BrightroomParametric** - Dependency-free parametric editing vocabulary
   - An edit is a root feature: a static composition of features, the way a
     SwiftUI view composes its body: `Feature`, `ImageEffect`,
     `FeatureBuilder` (`if`, `switch`, `for`, optional members, `#available`)
   - Built-in features (`ExposureFeature`, `GaussianBlurFeature`,
     `CropFeature`, `ToneCurveFeature`, `ColorMixerFeature`, ...),
     `FilterFeature`, `LocalAdjustmentFeature` with a `Mask`, and
     `AnyImageEffect` for content decided by data
   - `FeatureRenderer`, `ExportRenderer`, and `VideoRenderer` evaluate any
     `some Feature` into a Core Image graph
   - Crop value types live next to `CropFeature`: `AspectRatio`,
     `QuarterTurn`, `CropGeometry`
   - Features are plain values with no identity: no `FeatureID`, no
     `isEnabled`. (`FilterFeature.id` and `ColorCubeFeature.id` are string
     lookup keys for a filter or a LUT, not feature identity.)
     The library owns no storage format: apps convert features to their own
     `Codable` models and rebuild them through public, validating initializers
     (`docs/parametric-persistence.md`)

2. **BrightroomEngine** - Source images and editing documents (depends on BrightroomParametric)
   - `Sources/BrightroomEngine/DataSource/` - `SourceImage`: the image a
     document is authored over (data, file, `UIImage`, `CGImage`, RAW, Photos
     asset), with its oriented `pixelSize`
   - `Sources/BrightroomEngine/Core/` - `EditingDocument<Content>` (the source
     image, the root feature, and its commit-style `History`;
     `render(options:)`), and the package `EditingStack`, which prepares a
     thumbnail and the GPU-resident editing source for BrightroomUI's editors.
     It holds no edit and no history
   - `Sources/BrightroomEngine/Engine/` - internal image decoding
     (`ImageDecoding`) and preview preparation
   - Uses swift-state-graph for observable state

3. **BrightroomUI** - SwiftUI image editing components (UIKit internally)
   - `Sources/BrightroomUI/ImageEditor/` - the built-in editor `ImageEditor`,
     its root feature `ImageEditorFeature`, and `ImageEditorDocument`
     (`EditingDocument<ImageEditorFeature>`), which the host owns with its
     history
   - `Sources/BrightroomUI/Canvas/` - the editing canvas: the public
     `ImageEditorCanvas`, the internal UIKit `EditingCanvasView`, and its
     Metal surface
   - `Sources/BrightroomUI/Shared/` - Shared UI utilities and components
   - `ImageEditor` and `ImageEditorCanvas` edit an `ImageEditorDocument`
     through a binding

### Key Concepts

The vocabulary is defined in `docs/vision-of-editing.md` ("Vocabulary"). Use
one word per concept in names and docs.

- **Source image** (`SourceImage`): the image an edit is authored over. It is
  fixed for a document's lifetime.
- **Feature**: one step of an edit. The **root feature** is the feature a
  document holds, such as `ImageEditorFeature`.
- **Document** (`EditingDocument`): the source image, the root feature, and
  its undo history. "Document" means only this type; do not call a root
  feature a document.
- **Editor** (`ImageEditor`) and **canvas** (`ImageEditorCanvas`): the UI that
  edits a document through a binding. The host owns the document; the UI
  decides when to `commit()` an undo step.
- **Adjustment point**: the feature a tool edits, chosen with
  `ImageEditorCanvas.editingTarget(_:)`, while the canvas shows the evaluated
  result (the viewing point).
- **Chain-entry extent**: the extent proportional radii resolve against.
- **EditingStack** (package): per-image preview preparation owned by an editor
  view (`OwnedEditingStack`). Apps never create one.

### Editing Engine Vision

Read `docs/vision-of-editing.md` before making architectural changes to
BrightroomEngine, EditingStack, crop/mask/adjustment semantics, or renderer
evaluation strategy. The target direction is an Onshape-like parametric editing
stack where Features such as Crop, Mask, and Adjust can repeat, pass their
results downstream, and compile into a Core Image graph.
`docs/parametric-runtime-design.md` describes the feature model itself.

### State Management

The project uses swift-state-graph for observable state. When modifying state-related code:
- Look for `@GraphStored` properties
- Documents flow from the host's binding (`Binding<ImageEditorDocument>`)
  into `EditingCanvasView`; each completed operation is written back to the
  binding once, never per gesture tick and never during a view update
- A document compares by value; writes that leave the feature equal are
  dropped, so they add no history checkpoint

## Development Guidelines

### Adding New Effects
1. Add a value type in `Sources/BrightroomParametric/` conforming to
   `ImageEffect` and `Equatable`. A primitive effect implements
   `apply(to:context:)` and returns an image cropped to the input extent
   (see `BuiltInFeatureRecipes.swift`). A composite effect declares `body`
   instead.
2. Resolve proportional (value-form) radii through
   `context.chainEntryExtent(for:)`, so they resolve against the chain entry.
3. Keep every authored parameter reconstructible through public API; add a
   validating initializer when a plain initializer clamps or repairs values.
   Do not add `Codable` conformances or storage formats to the library
4. Do not add an identity `id` or `isEnabled`: enablement is structural (an optional
   member, `if`, or leaving a node out). An exact neutral bypass (returning
   the input image itself) belongs inside `apply(to:context:)`.
5. To surface it in ImageEditor, add an optional member to
   `ImageEditorFeature.Effects` (its `body` order is the evaluation order) and
   an `ImageEditor.Adjustment` case.
6. Test it against an explicit Core Image recipe in
   `Tests/BrightroomParametricTests`.

### Naming
- A top-level library type that conforms to `Feature` ends in `Feature`
  (`ExposureFeature`, `LocalAdjustmentFeature`, `ImageEditorFeature`). A
  type nested inside a feature as one of its parts may omit it
  (`ImageEditorFeature.Effects`). Keep the suffix on top-level types; do not
  introduce bare nouns such as `Crop` or `Exposure`, which hosts often
  declare themselves. Type-erased wrappers are `Any` plus the protocol name
  (`AnyImageEffect`).
- A value that is not a feature has no suffix (`Mask`, `BrushMask`,
  `QuarterTurn`, `AspectRatio`).
- A parameter type used by only one feature is nested in it
  (`GaussianBlurFeature.Radius`, `ToneCurveFeature.Curves`,
  `HighlightShadowTintFeature.Color`).
- Name parameters by their unit or meaning (`ev`, `intensity`,
  `temperature`) rather than `value` when one exists.
- "Renderer" is reserved for the public types that evaluate features
  (`FeatureRenderer`, `ExportRenderer`, `VideoRenderer`); `makeImage` returns
  a lazy `CIImage` recipe and `render` produces pixels.
- Do not give new types module or history prefixes (`Parametric`,
  `PhotosCrop`, `PixelEditor`) or leading underscores.
- "Display" is reserved for the viewport; image-space conversions say what
  they convert (`topLeftRect`). "Source" is the chain entry; a feature's own
  input is its "input" (`inputToOutputTransform`).

### Working with Metal
- Metal shaders are in `Sources/BrightroomParametric/` (brush masks and mask
  combinators) and `Sources/BrightroomColorAdjustmentKernels/` (tone curve and
  color mixer)
- Performance-critical operations use Metal instead of Core Image
- The editing canvas (`EditingCanvasView`) draws through `EditingCanvasMTKView`
  and `EditingCanvasRenderer`, and live brush strokes through
  `BrushMaskMetalRasterizer` (`Sources/BrightroomUI/Canvas/`);
  `_MetalImageView` (`Shared/Components/ImageViews/`) displays a `CIImage`

### Testing
- Engine and UI tests are in `Dev/Tests/BrightroomEngineTests/`
- Parametric tests are in `Tests/BrightroomParametricTests/`
- Focus on testing image processing logic, not UI
- Use provided test images in Resources for consistency

```bash
# Engine and UI tests
xcodebuild -project Dev/Brightroom.xcodeproj -scheme BrightroomEngineTests test \
  -destination 'platform=iOS Simulator,name=<simulator>' \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -skipMacroValidation -skipPackagePluginValidation

# Parametric tests
xcodebuild -scheme Brightroom-Package test \
  -destination 'platform=iOS Simulator,name=<simulator>' \
  -only-testing:BrightroomParametricTests \
  -skipMacroValidation -skipPackagePluginValidation
```

### Demo App
- **SwiftUI Demo**: `Dev/Sources/SwiftUIDemo/` - SwiftUI examples and UIKit-based checks wrapped with representables
- **ParametricMacDemo**: `Dev/ParametricMacDemo/` - the parametric engine on macOS

## Common Tasks

### Presenting the Built-in Editor
```swift
import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import SwiftUI
import UIKit

struct EditorScreen: View {
  // 1. The host owns the document: the image, the edit, and its history
  @State var document: ImageEditorDocument
  var didExport: (Result<UIImage, Error>) -> Void

  var body: some View {
    // 2. The built-in editor edits it through a binding
    ImageEditor(
      document: $document,
      onDone: {
        // 3. Render the edited document
        let document = document
        Task {
          do {
            let rendered = try await document.render()
            didExport(.success(try rendered.uiImage))
          } catch {
            didExport(.failure(error))
          }
        }
      }
    )
  }
}

// Create the document before showing the editor, for example:
func makeEditorScreen(fileURL: URL) throws -> EditorScreen {
  EditorScreen(
    document: ImageEditorDocument(image: try SourceImage(contentsOf: fileURL)),
    didExport: { _ in }
  )
}
```

### Adding Custom UI Component
1. Create component in `Sources/BrightroomUI/`
2. Accept a `Binding<ImageEditorDocument>` (or another `EditingDocument`);
   prepare the image for display through `OwnedEditingStack`, keyed by the
   document's `SourceImage`
3. Write each completed change to the binding's latest document once; leave
   `commit()` to the editor that owns the undo granularity
4. Do not store edits in `EditingStack`; it only prepares the preview

## Platform Requirements
- iOS 17.0+ (BrightroomUI, BrightroomEngine)
- iOS 17.0+ and macOS 14.0+ (BrightroomParametric)
- Swift 6.3+ (Swift 6 language mode)
- Supports iPhone and iPad
