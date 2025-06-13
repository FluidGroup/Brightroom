# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Brightroom is a composable image editor library for iOS, powered by Metal for high-performance image processing. It provides both low-level image editing capabilities and high-level UI components.

## Build Commands

### Running Demo Apps
```bash
# Open the development workspace
open Dev/Brightroom.xcodeproj

# Build using Fastlane
fastlane ios build_demo_apps
```

### Building the Package
```bash
# Build the Swift package
swift build
```

## Architecture

### Core Modules

1. **BrightroomEngine** - Core image processing engine
   - `Sources/BrightroomEngine/Core/` - Core data models (EditingStack, ImageProvider)
   - `Sources/BrightroomEngine/Filter/` - Image filters and effects
   - `Sources/BrightroomEngine/Engine/` - Metal-based rendering pipeline
   - Uses Verge for reactive state management

2. **BrightroomUI** - UI components for image editing
   - `Sources/BrightroomUI/Shared/` - Shared UI utilities and components
   - `Sources/BrightroomUI/Built-in/` - Pre-built editor UIs (ClassicImageEdit)
   - Provides both UIKit and SwiftUI interfaces

3. **BrightroomUIPhotosCrop** - iOS Photos app-style cropping UI
   - Specialized cropping interface matching system Photos app behavior

### Key Concepts

- **EditingStack**: Central state container that manages editing history and coordinates rendering. Think of it as a "headless browser" for image editing.
- **ImageProvider**: Abstraction for various image sources (UIImage, URL, Data)
- **Renderer**: Metal-based rendering system that applies filters and transformations
- **Component-based UI**: All UI components can be used standalone or composed together

### State Management

The project uses Verge (swift-state-graph) for state management. When modifying state-related code:
- Look for `@Observable` macro usage
- State changes flow through EditingStack
- UI components observe EditingStack changes reactively

## Development Guidelines

### Adding New Filters
1. Create new filter class in `Sources/BrightroomEngine/Filter/`
2. Inherit from appropriate base class (e.g., `CIImageFilter`)
3. Define parameters as properties
4. Implement `apply(to:)` method
5. Register in `FilterPresets` if it should appear in UI

### Working with Metal
- Metal shaders are in `Sources/BrightroomEngine/Engine/`
- Performance-critical operations use Metal instead of Core Image
- Check `MetalImageView` for Metal rendering pipeline

### Testing
- Unit tests are in `Dev/Tests/BrightroomEngineTests/`
- Focus on testing image processing logic, not UI
- Use provided test images in Resources for consistency

### Demo Apps
- **UIKit Demo**: `Dev/Sources/Demo/` - Traditional UIKit implementation
- **SwiftUI Demo**: `Dev/Sources/SwiftUIDemo/` - Modern SwiftUI examples
- Both demos showcase all major features and serve as implementation references

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
