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
   - Documents are static compositions of features, the way a SwiftUI view
     composes its body: `Feature`, `ImageEffect`, `FeatureBuilder` (`if`,
     `switch`, `for`, optional members, `#available`)
   - Built-in features (`ExposureFeature`, `GaussianBlurFeature`,
     `CropFeature`, `ToneCurveFeature`, `ColorMixerFeature`, ...),
     `PresetFeature`, `LocalAdjustment` with a `MaskTree`, and
     `AnyImageEffect` for content decided by data
   - `ParametricImageRenderer`, `ParametricExportRenderer`, and
     `ParametricVideoRenderer` evaluate any `some Feature` document into a
     Core Image graph
   - Features are plain values with no identity: no `id`, no `isEnabled`.
     The library owns no storage format: apps convert features to their own
     `Codable` models and rebuild them through public, validating initializers
     (`docs/parametric-persistence.md`)

2. **BrightroomEngine** - Image loading and rendering (depends on BrightroomParametric)
   - `Sources/BrightroomEngine/Core/` - `EditingStack` (loads and prepares an
     image, renders a document with `makeRenderer(document:)`; holds no edit
     and no history)
   - `Sources/BrightroomEngine/DataSource/` - `ImageProvider`
   - `Sources/BrightroomEngine/Engine/` - Rendering pipeline (`BrightRoomImageRenderer`)
   - Uses swift-state-graph for observable state

3. **BrightroomUI** - UI components for image editing
   - `Sources/BrightroomUI/Shared/` - Shared UI utilities and components
     (CropView, EditingCanvas Metal surface)
   - `Sources/BrightroomUI/ImageEditor/` - the built-in editor `ImageEditor`,
     its root feature `ImageEditorFeature`, and `ImageEditorDocument`
     (`EditingDocument<ImageEditorFeature>`), which the host owns with its
     history
   - `SwiftUICropView` edits an `ImageEditorFeature` through a binding
   - Provides both UIKit and SwiftUI interfaces

### Key Concepts

- **Document**: a `Feature` value that describes an edit, such as
  `ImageEditorFeature`. The UI that edits an image defines and owns its
  document; the document's owner keeps its history (`PhotosCropEditingModel`).
- **EditingStack**: loads an image (metadata, orientation, thumbnail, and the
  downsampled editing source) and renders documents over it. It holds no edit.
- **ImageProvider**: Abstraction for various image sources (UIImage, URL, Data)
- **Renderer**: Metal-based rendering system that applies filters and transformations
- **Component-based UI**: All UI components can be used standalone or composed together

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
- Document values flow from the owning model (`PhotosCropEditingModel`) or
  binding into `CropView`; `CropView` reports changes back to the owner
- A document compares by value; an owner drops an update that leaves the
  document equal, so it adds no history checkpoint

## Development Guidelines

### Adding New Effects
1. Add a value type in `Sources/BrightroomParametric/` conforming to
   `ImageEffect` and `Equatable`. A primitive effect implements
   `apply(to:context:)` and returns an image cropped to the input extent
   (see `BuiltInFeatureRecipes.swift`). A composite effect declares `body`
   instead.
2. Resolve proportional (value-form) radii through
   `context.radiusBasis(for:)`, so they resolve against the chain entry.
3. Keep every authored parameter reconstructible through public API; add a
   validating initializer when a plain initializer clamps or repairs values.
   Do not add `Codable` conformances or storage formats to the library
4. Do not add `id` or `isEnabled`: enablement is structural (an optional
   member, `if`, or leaving a node out). An exact neutral bypass (returning
   the input image itself) belongs inside `apply(to:context:)`.
5. To surface it in ImageEditor, add an optional member to
   `ImageEditorFeature.Effects` (its `body` order is the evaluation order) and
   an `ImageEditor.Adjustment` case.
6. Test it against an explicit Core Image recipe in
   `Tests/BrightroomParametricTests`.

### Working with Metal
- Metal shaders are in `Sources/BrightroomParametric/` (brush masks and mask
  combinators) and `Sources/BrightroomColorAdjustmentKernels/` (tone curve and
  color mixer)
- Performance-critical operations use Metal instead of Core Image
- The CropView editing canvas draws through `_EditingCanvasMTKView` and
  `EditingCanvasRenderer`, and live brush strokes through
  `BrushMaskMetalRasterizer` (`Sources/BrightroomUI/Shared/Components/EditingCanvas/`);
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

### Implementing Custom Image Editor
```swift
// 1. Create a model over an EditingStack; keep it for the session
let editingModel = PhotosCropEditingModel(
  editingStack: EditingStack(imageProvider: .init(image: uiImage))
)

// 2. Use the built-in UI or create a custom one
let editor = ImageEditor(
  editingModel: editingModel,
  onDone: { document in
    // 3. Render the edited document
    Task {
      do {
        let rendered = try await editingModel.editingStack
          .makeRenderer(document: document)
          .render()
        didExport(.success(try rendered.uiImage))  // your handler
      } catch {
        didExport(.failure(error))
      }
    }
  },
  onCancel: {}
)
```

### Adding Custom UI Component
1. Create component in `Sources/BrightroomUI/`
2. Accept `EditingStack` for loading, plus a document value or binding
3. Observe the stack's `loadedState` for the loaded image
4. Report document changes to the document's owner; do not store edits in the stack

## Platform Requirements
- iOS 17.0+ (BrightroomUI, BrightroomEngine)
- iOS 17.0+ and macOS 14.0+ (BrightroomParametric)
- Swift 6.3+ (Swift 6 language mode)
- Supports iPhone and iPad
