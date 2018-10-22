# Pixel - Engine • Editor

The image editor and engine using CoreImage

> ⚠️ Currently, API is not stable. It may change in the future.

<img src=PixelEngine.png width=960/>

## Features

**Currently it's accepting PR that impemented features.**

* Adjustment
  * [x] Crop
  * [ ] Straighten
  * [ ] Perspective

* Filter
  * [x] ColorCube (Look Up Table)
  * [x] Brightness
  * [x] Contrast
  * [x] Saturation
  * [x] Highlights
  * [x] Shadows
  * [x] Temperature
  * [x] GaussianBlur
  * [x] Vignette 
  * [ ] Color (Shadows / Highlights)
  * [x] Fade
  * [x] Sharpen
  * [x] Clarity
  * [ ] HLS
  
## Requirements
 
* Swift 4.2 (Xcode10+)
* iOS 10+
  
## Getting Started

Demo.app contains the sample code.
Please check out `Sources/Demo/EditorViewController.swift`.

### Create instance of PixelEditViewController

```swift
let image: UIImage

let controller = PixelEditViewController(image: image)
```

### Show

* as Modal

⚠️ Currently
We need to wrap the controller with `UINavigationController`.
Because, `PixelEditViewController` needs `UINavigationBar`.

```swift
let controller: PixelEditViewController

let navigationController = UINavigationController(rootViewController: controller)

self.present(navigationController, animated: true, completion: nil)
```

* as Push

We can push the controller in UINavigationController.

```swift
let controller: PixelEditViewController
self.navigationController.push(controller, animated: true)
```

### Setup Delegate

`PixelEditViewController` has delegate protocol called `PixelEditViewControllerDelegate`.

```swift
public protocol PixelEditViewControllerDelegate : class {
  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing image: UIImage)
  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController)
}
```

💡`PixelEditViewController` does not have how to dismiss or pop.
So we need to control `PixelEditViewController` outside.

Basically, it's like following code, recommend dismiss or pop in methods of delegate.

```swift
extension EditorViewController : PixelEditViewControllerDelegate {

  func pixelEditViewController(_ controller: PixelEditViewController, didEndEditing image: UIImage) {

    self.navigationController?.popToViewController(self, animated: true)
  }
  
  func pixelEditViewControllerDidCancelEditing(in controller: PixelEditViewController) {
    self.navigationController?.popToViewController(self, animated: true)
  }
  
}
```

### Restore editing

We can take current editing as instance of `EditingStack` from `PixelEditViewController.editingStack`.

If we want to restore editing after closed `PixelEditViewController`, we use this.

```swift
let editingStack = controller.editingStack
// close editor

// and then when show editor again
let controller = PixelEditViewController(editingStack: editingStack)
```

### Add ColorCubeFilters

We can use LUT(LookUpTable) with CIColorCubeFilter.

LUT is like this (Dimension is 64)

<img src="neutral-lut.png" />

```swift
import PixelEngine

let lutImage: UIImage

let filter = FilterColorCube(
  name: "Filter Name",
  identifier: "Filter Identifier",
  lutImage: lutImage,
  dimension: 64
)

let controller = PixelEditViewController(image: image, colorCubeFilters: [filter])
```

And also, we can add the filters to cache storage called `ColorCubeStorage`.

```swift
// set
ColorCubeStorage.load(filters: [filter])

// get
ColorCubeStorage.filters
```
  
## Customize Control-UI

We can customize UI for control area.

<img src="customize.png" width=375/>

### Customize Built-In Control-UI using override

There is `Options` struct in PixelEditor.
We can create options that fits our usecases.

So, If we need to change BrightnessControl, override BrightnessControlBase class.
Then set that class to Options.

```swift
let options = Options.default()
options.classes.control.brightnessControl = MyBrightnessControl.self
```

It's like using custom Cell in UICollectionView.
If you have any better idea for this, please tell us💡.

### Customize whole Control-UI

We can also customize whole UI.

Override `options.classes.control.rootControl`, then build UI from scratch.

## Localization

Strings in UI can be localized with `L10n`.

```swift
import PixelEditor

PixelEditor.L10n.done = "保存"

// or
PixelEditor.L10n.done = NSLocalizedString...
```
  
## Installation

### CocoaPods

Pixel is available through [CocoaPods](https://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'PixelEngine'
pod 'PixelEditor'
```

### Carthage

For [Carthage](https://github.com/Carthage/Carthage), add the following to your `Cartfile`:

```ogdl
github "muukii/Pixel"
```

## Contributing

If you need more features, please open issue or submit PR!
Muukii does not know all approach for features, So your PR will be very helpful.

## Author

Muukii (muukii.app@gmail.com)

## License

Pixel is available under the MIT license. See the LICENSE file for more info.
