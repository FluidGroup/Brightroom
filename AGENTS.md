# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Brightroom is a composable image editor library for iOS, powered by Metal for high-performance image processing. It provides both low-level image editing capabilities and high-level UI components.

## Build Commands

### Building via Xcode Project (Recommended)
```bash
# Build BrightroomUI (includes BrightroomEngine)
cd Dev && xcodebuild -scheme BrightroomUI -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# Build SwiftUI Demo app
cd Dev && xcodebuild -scheme SwiftUIDemo -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
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
   - Typed effect/mask/crop features (`ExposureFeature`, `GaussianBlurFeature`,
     `LocalAdjustmentFeature`, `MaskTree`, `EffectPipeline`, ...)
   - `FeatureGraphCompiler` / renderers compile features into Core Image graphs
   - `ParametricDocumentCodec` is the persistence boundary (runtime stays a
     Swift value tree; Codable is only for saving)

2. **BrightroomEngine** - Core image processing engine (depends on BrightroomParametric)
   - `Sources/BrightroomEngine/Core/` - Core data models (EditingStack, ImageProvider);
     `EditingStack.Edit` stores `[EditingFeature]` whose payloads carry parametric types
   - `Sources/BrightroomEngine/Engine/` - Rendering pipeline (BrightRoomImageRenderer)
   - Uses Verge for reactive state management

3. **BrightroomUI** - UI components for image editing
   - `Sources/BrightroomUI/Shared/` - Shared UI utilities and components
     (CropView, EditingCanvas Metal surface)
   - `Sources/BrightroomUI/builtin/PhotosCrop/` - iOS Photos app-style editor
   - Provides both UIKit and SwiftUI interfaces

### Key Concepts

- **EditingStack**: Central state container that manages editing history and coordinates rendering. Think of it as a "headless browser" for image editing.
- **ImageProvider**: Abstraction for various image sources (UIImage, URL, Data)
- **Renderer**: Metal-based rendering system that applies filters and transformations
- **Component-based UI**: All UI components can be used standalone or composed together

### Editing Engine Vision

Read `docs/vision-of-editing.md` before making architectural changes to
BrightroomEngine, EditingStack, crop/mask/adjustment semantics, or renderer
evaluation strategy. The target direction is an Onshape-like parametric editing
stack where Features such as Crop, Mask, and Adjust can repeat, pass their
results downstream, and compile into a Core Image graph.

### State Management

The project uses Verge (swift-state-graph) for state management. When modifying state-related code:
- Look for `@Observable` macro usage
- State changes flow through EditingStack
- UI components observe EditingStack changes reactively

## Development Guidelines

### Adding New Effects
1. Create a value-type feature in `Sources/BrightroomParametric/` conforming to
   `ImageEffectFeatureType` (requires `id: FeatureID`, `isEnabled`, and
   `apply(to:context:)`; `validate()`/`childFeatures` have defaults)
2. Implement the recipe as a `CIImage -> CIImage` transform (see
   `BuiltInFeatureRecipes.swift`)
3. Conform to `PersistableFeature` and register it in `ParametricDocumentCodec`
   if documents should persist it
4. Surface it in UI by upserting into the global-effects `EffectPipeline`
   (PhotosCrop orders effects via `PhotosCropEffectOrder`)
5. Give programmatically-created features deterministic `FeatureID(rawValue:)`
   ids when equal values must compare equal across calls (cache keys, presets)

### Working with Metal
- Metal shaders are in `Sources/BrightroomEngine/Engine/`
- Performance-critical operations use Metal instead of Core Image
- Check `MetalImageView` for Metal rendering pipeline

### Testing
- Unit tests are in `Dev/Tests/BrightroomEngineTests/`
- Focus on testing image processing logic, not UI
- Use provided test images in Resources for consistency

### Demo App
- **SwiftUI Demo**: `Dev/Sources/SwiftUIDemo/` - SwiftUI examples and UIKit-based checks wrapped with representables

## Common Tasks

### Implementing Custom Image Editor
```swift
// 1. Create EditingStack with image
let stack = EditingStack(imageProvider: .init(image: uiImage))

// 2. Use built-in UI or create custom
let editor = ClassicImageEditViewController(editingStack: stack)

// 3. Handle completion
editor.handlers.didEndEditing = { stack in
    let rendered = try! stack.makeRenderer().render().uiImage
}
```

### Adding Custom UI Component
1. Create component in `Sources/BrightroomUI/`
2. Accept `EditingStack` as dependency
3. Observe stack changes using Verge
4. Update stack through appropriate methods

## Platform Requirements
- iOS 16.0+
- Xcode 15.2+
- Swift 5.9+
- Supports iPhone and iPad
