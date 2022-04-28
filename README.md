# Brightroom
**A composable image editor with a customizable UI.**

| Image Editor | Photo Cropping | Face Detection | Masking |
| --- | --- | --- | --- |
| <img width=200px src="https://user-images.githubusercontent.com/1888355/112865486-c9154880-90f3-11eb-89eb-bc55f924f517.gif" /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720381-4ea4c700-8f41-11eb-8ec3-2446518ded1b.gif /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720303-cde5cb00-8f40-11eb-941f-c134368b87c5.gif /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112927084-6487d700-914f-11eb-86a5-28f9373285e6.gif /> |

> [🎄**An open-sourced app built with Brightroom**](https://github.com/muukii/Drip.app)

## 🎉 v2 is Now Open!
There are a few important housekeeping notes for those coming from v1.

 - ⚒ Issues are managed in the [v2 Project](https://github.com/muukii/Brightroom/projects/2)
 - 📌 Pixel has been renamed **Brightroom**.
 - 📖 Detailed documentation is available [on Notion](https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162).
 - 🎈 **Help Wanted**: CoreImage and Metal professionals!
 - ⭐️ If you're interested in v2, **star the project** to motivate us! 🤠
 - 🪐 Brightroom's state management is now powered by [Verge](https://github.com/VergeGroup/Verge).
 - 💵 Support me on [GitHub](https://github.com/sponsors/muukii?frequency=one-time&sponsor=muukii).

## Support the project
<a href="https://www.buymeacoffee.com/muukii">
<img width="545" alt="yellow-button" src="https://user-images.githubusercontent.com/1888355/146226808-eb2e9ee0-c6bd-44a2-a330-3bbc8a6244cf.png">
</a>


## Brightroom v2 provides the following features:
- Components are built separately and run standalone using an `EditingStack`.
- **Create your own image editor UI** by composing components.
- `EditingStack` manages the history of editing and renders images. It's like a headless browser.
- Headless rendering with using `EditingStack`
- [Wide color editing supported](https://instagram-engineering.com/bringing-wide-color-to-instagram-5a5481802d7d)
- [Super large photo (12000px)](https://eoimages.gsfc.nasa.gov/images/imagerecords/78000/78314/VIIRS_3Feb2012_lrg.jpg) supported (But exporting takes so long time for now.)
- Blazing fast previewing by Metal power.
- Drawing supported - masking blurry
- Creating your own filter with LUT
- Opening the image from URL
- Supported UIKit and SwiftUI
- Downloading image supported

## Requirements

* Swift 5.3 (Xcode 12.4+)
* iOS 12+

## Detailed Documentation

<b><a href="https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162">Documentations</a></b>

## Usage

**PhotosCropViewController**

```swift
// Creating image provider
let imageProvider: ImageProvider = .init(image: uiImage) // url, data supported.

// Creating view controller
let controller = PhotosCropViewController(imageProvider: imageProvider)

// Setting up handling after editing finished.
controller.handers
```

## SwiftUI Support (BETA)
*The SwiftUI API is still in-progress and may not be production ready. We're looking for help! 🤲*

```swift
let editingStack: EditingStack

SwiftUIPhotosCropView(editingStack: editingStack, onCompleted: {
  let image = try! editingStack.makeRenderer().render().swiftUIImage
  
})
```

## Demo Application

This repository contains a demo application. You can see many demonstrations of what Brightroom can perform and experiments in technology.

|||
|---|---|
|<img width=200px src=https://user-images.githubusercontent.com/1888355/113339348-4bf10a00-9365-11eb-915b-dc9e54801fcd.PNG />|<img width=200px src=https://user-images.githubusercontent.com/1888355/113339357-4dbacd80-9365-11eb-80a5-53792b616360.PNG />|

## Customization showcases

|  | 
| --- |
| <img width=200px src="https://user-images.githubusercontent.com/1888355/112861131-7cc80980-90ef-11eb-9d43-8c706abeb9d5.png" /> | 


## Installation

**CocoaPods**

```ruby
pod 'Brightroom/Engine'
pod 'Brightroom/UI-Classic'
pod 'Brightroom/UI-Crop'
```

**Swift Package Manager**

```swift
dependencies: [
    .package(url: "https://github.com/muukii/Brightroom.git", exact: "2.2.0")
]
```

## License

Brightroom is available under the MIT license. See the LICENSE file for more info.

[![FOSSA Status](https://app.fossa.io/api/projects/git%2Bgithub.com%2Fmuukii%2FPixel.svg?type=large)](https://app.fossa.io/projects/git%2Bgithub.com%2Fmuukii%2FPixel?ref=badge_large)
