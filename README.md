<h1 align=center>Brightroom</h1>
<p align=center><i>A full-featured composable image editor with a customizable UI -- all backed by the power of Metal.</i></p>
<br/>

| Image Editor | Photo Cropping | Face Detection | Masking |
| --- | --- | --- | --- |
| <img width=200px src="https://user-images.githubusercontent.com/1888355/112865486-c9154880-90f3-11eb-89eb-bc55f924f517.gif" /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720381-4ea4c700-8f41-11eb-8ec3-2446518ded1b.gif /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112720303-cde5cb00-8f40-11eb-941f-c134368b87c5.gif /> | <img width=200px src=https://user-images.githubusercontent.com/1888355/112927084-6487d700-914f-11eb-86a5-28f9373285e6.gif /> |

## Features

- **Create your own image editor UI** by composing components.
  - Components are built separately and run standalone using an `EditingStack`.
  - `EditingStacks` **manage editing history** and render images. *It's like a headless browser!*
- Edit and render using [**P3 Wide Color** Gamut](https://instagram-engineering.com/bringing-wide-color-to-instagram-5a5481802d7d)
- Support for [Super Large Photos™ (≤ 12000 pixels)](https://eoimages.gsfc.nasa.gov/images/imagerecords/78000/78314/VIIRS_3Feb2012_lrg.jpg).
- Previews and rendering backed with the power of **Metal**.
- Create custom-drawn **masks** on photos.
- Drop-in support for your own **custom filters using LUTs**.
- Load and download **remote images** for editing with a `URL`.
- Support for both UIKit and SwiftUI.

## Requirements

| iOS Target | Xcode Version | Swift Version |
|:---:|:---:|:---:|
| iOS 12.0+ | Xcode 12.4+ | Swift 5.3+ |

## Support the Project
Buy me a coffee or support me on [GitHub](https://github.com/sponsors/muukii?frequency=one-time&sponsor=muukii).

<a href="https://www.buymeacoffee.com/muukii">
<img width=25% alt="yellow-button" src="https://user-images.githubusercontent.com/1888355/146226808-eb2e9ee0-c6bd-44a2-a330-3bbc8a6244cf.png">
</a>

## 🎉 v2 Now Available!
There are a few important housekeeping notes for those coming from v1.

 - ⚒ Issues are managed in the [v2 Project](https://github.com/muukii/Brightroom/projects/2)
 - 📌 Pixel has been renamed **Brightroom**.
 - 📖 Detailed documentation is available [on Notion](https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162).
 - 🎈 **Help Wanted**: CoreImage and Metal professionals!
 - ⭐️ If you're interested in v2, **star the project** to motivate us! 🤠
 - 🪐 Brightroom's state management is now powered by [Verge](https://github.com/VergeGroup/Verge).

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
    .package(url: "https://github.com/muukii/Brightroom.git", upToNextMajor: "2.2.0")
]
```

# Documentation

View the [full documentation](https://www.notion.so/muukii/Brightroom-d4c59b37610a49de8a14131d24cd6162) on Notion.

## Usage

**PhotosCropViewController**

```swift
// Create an image provider
let imageProvider = ImageProvider(image: uiImage) // URL, Data are also supported.

// Create a Photo Crop View Controller
let controller = PhotosCropViewController(imageProvider: imageProvider)

// Set up handlers when editing finishes
controller.handers
```

## SwiftUI Support (BETA)
*The SwiftUI API is still in-progress and may not be production ready. We're looking for help! 🤲*

```swift
let editingStack: EditingStack

SwiftUIPhotosCropView(editingStack: editingStack) {
  let image = try! editingStack.makeRenderer().render().swiftUIImage
}
```

# Demo & Full App
There is an entire open-source and production-ready app available on the App Store that uses Brightroom. It's called [Drip](https://github.com/muukii/Drip.app).

This repository also contains a demo app which demonstrates what Brightroom can perform and showcases some easy experiments. Clone this repo and build the project to try it out!

# License

Brightroom is available under the MIT license. See the LICENSE file for more info.

# Status

[![FOSSA Status](https://app.fossa.io/api/projects/git%2Bgithub.com%2Fmuukii%2FPixel.svg?type=large)](https://app.fossa.io/projects/git%2Bgithub.com%2Fmuukii%2FPixel?ref=badge_large)
